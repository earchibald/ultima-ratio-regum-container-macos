#!/usr/bin/env python3
"""Build the launcher's "Developer blog" page: site/posts.json embedded in
site/index.html, wrapped as a standalone document -> dist/index.html.

The template and data come from the URR Blog Reader project
(~/Code/urr-blog-reader); its index.html is an Artifact fragment without
<html>/<head>, so the wrapper adds those. Refresh the data with scrape.py
(needs beautifulsoup4), then run this. The page shows excerpts and section
outlines only and links out to markrjohnsongames.com for the full posts.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
data = json.loads((ROOT / "site" / "posts.json").read_text())
payload = json.dumps(data, ensure_ascii=False, indent=1).replace("</", "<\\/")
fragment = (ROOT / "site" / "index.html").read_text()
assert "/*POSTS_JSON*/" in fragment, "template marker missing"
page = (
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n</head>\n<body>\n"
    + fragment.replace("/*POSTS_JSON*/", payload, 1)
    + "\n</body>\n</html>\n"
)
out = ROOT / "dist" / "index.html"
out.parent.mkdir(exist_ok=True)
out.write_text(page)
print(f"{out} ({out.stat().st_size // 1024} KB, {len(data['posts'])} posts)")
