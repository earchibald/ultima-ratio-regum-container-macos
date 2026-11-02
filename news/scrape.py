#!/usr/bin/env python3
"""Scrape Mark R Johnson's blog into site/posts.json.

  scrape.py --full     walk every /blog/page/N/ index page and fetch every post
  scrape.py            incremental: check the RSS feed + first index page, fetch
                       new posts, and refresh the newest few (comments, edits)

Exit codes: 0 = nothing worth republishing, 10 = new or edited posts, 1 = error.
Raw post HTML is cached in cache/ so a --full re-run is cheap and polite.
"""
import argparse
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

from bs4 import BeautifulSoup

BASE = "https://www.markrjohnsongames.com"
ROOT = Path(__file__).resolve().parent
OUT = ROOT / "site" / "posts.json"
CACHE = ROOT / "cache"
UA = "Mozilla/5.0 (urr-blog-reader; personal reading index)"
REFRESH_RECENT = 6

CATEGORY_NAMES = {
    "ultima-ratio-regum": "Ultima Ratio Regum",
    "game-design": "Game Design",
    "game-studies": "Game Studies",
    "updates": "Updates",
    "uncategorized": "Uncategorized",
    "pcg": "PCG",
}


def fetch(url, retries=3):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == retries - 1:
                raise
        except urllib.error.URLError:
            if attempt == retries - 1:
                raise
        time.sleep(2 * (attempt + 1))


def cached_fetch(url, refresh=False):
    key = hashlib.sha1(url.encode()).hexdigest()[:16]
    path = CACHE / f"{key}.html"
    if path.exists() and not refresh:
        return path.read_text()
    html = fetch(url)
    time.sleep(0.4)
    if html is not None:
        CACHE.mkdir(exist_ok=True)
        path.write_text(html)
    return html


def index_urls(page):
    url = f"{BASE}/blog/" if page == 1 else f"{BASE}/blog/page/{page}/"
    html = fetch(url)
    if html is None:
        return None
    soup = BeautifulSoup(html, "html.parser")
    return [a["href"] for a in soup.select("h2.entry-title a[href]")]


def feed_urls():
    xml = fetch(f"{BASE}/feed/")
    if not xml:
        return []
    return [i.findtext("link") for i in ElementTree.fromstring(xml).iter("item")]


def category_name(slug):
    return CATEGORY_NAMES.get(slug, slug.replace("-", " ").title())


def tidy(text):
    # get_text(" ") pads inline elements; undo the space it leaves before punctuation.
    return re.sub(r"\s+([.,;:!?)\]])", r"\1", re.sub(r"([(\[])\s+", r"\1", text))


def words(text, n):
    parts = tidy(text).split()
    return " ".join(parts[:n]) + ("…" if len(parts) > n else "")


def classify(title, categories):
    m = re.search(r"Ultima Ratio Regum\s+([\d.]+)\s+Update\s*#?(\d+)", title, re.I)
    if m:
        return {"series": "update", "version": m.group(1), "number": int(m.group(2))}
    if "Ultima Ratio Regum" in categories or re.search(r"Ultima Ratio Regum|URR", title, re.I):
        m = re.search(r"\b(0\.\d+)\b", title)
        return {"series": "urr", "version": m.group(1) if m else None, "number": None}
    if re.match(r"Interlude", title, re.I):
        return {"series": "interlude", "version": None, "number": None}
    return {"series": "other", "version": None, "number": None}


def parse_post(url, html):
    soup = BeautifulSoup(html, "html.parser")
    art = soup.find("article")
    content = art.select_one(".entry-content") if art else None
    if content is None:
        raise ValueError(f"no entry-content in {url}")

    title_el = soup.select_one("h1.entry-title") or soup.select_one('meta[property="og:title"]')
    title = title_el.get_text(strip=True) if title_el.name == "h1" else title_el["content"]
    title = re.sub(r"\s*\|\s*Dr Mark R Johnson$", "", title)

    def meta(prop):
        el = soup.select_one(f'meta[property="{prop}"]')
        return el["content"] if el else None

    published = meta("article:published_time")
    modified = meta("article:modified_time") or published
    if not published:
        m = re.search(r"/(\d{4})/(\d{2})/(\d{2})/", url)
        published = f"{m.group(1)}-{m.group(2)}-{m.group(3)}T12:00:00+00:00"

    cats = [c[len("category-"):] for c in art.get("class", []) if c.startswith("category-")]
    tags = [c[len("tag-"):].replace("-", " ") for c in art.get("class", []) if c.startswith("tag-")]

    # Section titles: real headings, or short paragraphs that are entirely bold.
    sections = []
    for el in content.find_all(["h1", "h2", "h3", "h4", "p"]):
        text = tidy(el.get_text(" ", strip=True))
        if not text or len(text) > 90:
            continue
        if el.name != "p":
            sections.append(text)
            continue
        bold = el.find(["strong", "b"])
        if bold and len(bold.get_text(strip=True)) >= len(el.get_text(strip=True)) - 2:
            sections.append(text)

    paras = [p.get_text(" ", strip=True) for p in content.find_all("p")]
    paras = [p for p in paras if len(p.split()) >= 12]
    opening = paras[0] if paras else ""
    # URR updates open with personal news; the first paragraph after the first
    # section title says what the update is actually about.
    lede = ""
    lead_sections = [t for t in sections if not re.match(r"(what next|conclusion|final thoughts)", t, re.I)]
    if lead_sections:
        seen = False
        for el in content.find_all("p"):
            t = el.get_text(" ", strip=True)
            if tidy(t) == lead_sections[0]:
                seen = True
                continue
            if seen and len(t.split()) >= 12:
                lede = t
                break

    body_text = content.get_text(" ", strip=True)
    word_count = len(body_text.split())

    comments_el = soup.select_one(".comments-title")
    comments = 0
    if comments_el:
        m = re.search(r"(\d+)", comments_el.get_text())
        comments = int(m.group(1)) if m else 0

    post = {
        "url": url,
        "slug": url.rstrip("/").rsplit("/", 1)[-1],
        "title": title,
        "published": published,
        "modified": modified,
        "categories": [category_name(c) for c in cats],
        "tags": tags,
        "sections": sections[:24],
        "opening": words(opening, 70),
        "lede": words(lede, 70) if lede and lede != opening else "",
        "words": word_count,
        "images": len(content.find_all("img")),
        "comments": comments,
    }
    post.update(classify(title, post["categories"]))
    return post


def load():
    if OUT.exists():
        return json.loads(OUT.read_text())
    return {"posts": []}


def save(data):
    data["posts"].sort(key=lambda p: p["published"], reverse=True)
    data["source"] = f"{BASE}/blog/"
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")


def run_full():
    urls, page = [], 1
    while True:
        found = index_urls(page)
        if not found:
            break
        urls.extend(u for u in found if u not in urls)
        print(f"index page {page}: {len(found)} posts", file=sys.stderr)
        page += 1
        time.sleep(0.4)
    posts = []
    for i, url in enumerate(urls, 1):
        html = cached_fetch(url)
        if html is None:
            print(f"skip (404) {url}", file=sys.stderr)
            continue
        posts.append(parse_post(url, html))
        print(f"[{i}/{len(urls)}] {posts[-1]['title']}", file=sys.stderr)
    data = load()
    data["posts"] = posts
    data["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    save(data)
    return 10


def run_incremental():
    data = load()
    known = {p["url"]: p for p in data["posts"]}
    candidates = []
    for url in feed_urls() + (index_urls(1) or []):
        if url and url not in candidates:
            candidates.append(url)
    recent = [p["url"] for p in sorted(data["posts"], key=lambda p: p["published"], reverse=True)[:REFRESH_RECENT]]
    changed = []
    for url in candidates + [u for u in recent if u not in candidates]:
        is_new = url not in known
        if not is_new and url not in recent:
            continue
        html = cached_fetch(url, refresh=True)
        if html is None:
            continue
        post = parse_post(url, html)
        old = known.get(url)
        if is_new:
            changed.append(f"new: {post['title']}")
        elif (old["title"], old["modified"], old["sections"]) != (post["title"], post["modified"], post["sections"]):
            changed.append(f"edited: {post['title']}")
        known[url] = post
    data["posts"] = list(known.values())
    if changed:
        data["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    save(data)
    for line in changed:
        print(line)
    return 10 if changed else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true")
    args = ap.parse_args()
    sys.exit(run_full() if args.full else run_incremental())
