# Ultima Ratio Regum for macOS (container edition)

A Mac launcher for Mark R Johnson's [Ultima Ratio Regum](https://www.markrjohnsongames.com/games/ultima-ratio-regum/).
The game is Windows-only, but underneath it is Python 3.7 + libtcod. This
launcher runs the **official, unmodified** game files in a small Linux VM
managed by Apple's open-source [`container`](https://github.com/apple/container)
runtime. There's no Docker, no Wine and no Rosetta, and it shows the game in a
native Mac window.

Tested with **URR 0.10.4d** and **container 1.6.1** on macOS 26+/27 (Apple silicon).

## What the player sees

`Ultima Ratio Regum.app` opens a setup window: a checklist of steps, any
decision cards, and a **looking glass**, which is a live console of every command the
launcher runs and its output (also written to `~/Library/Logs/Ultima Ratio Regum/`).

| Step | What happens | Player involvement |
|---|---|---|
| This Mac | Checks for Apple silicon and macOS 26+ | — |
| Game files | Uses the bundled official ZIP, or asks: **Download** from markrjohnsongames.com, or **Choose ZIP…** / drag the ZIP onto the window. Verifies the sha256 and unpacks it unmodified. | Only if no ZIP is bundled |
| Apple container runtime | If missing, offers three ways, all using Apple's signed `container-1.6.1-installer-signed.pkg` with its sha256 and Developer ID signature checked: **Install for me** (the launcher runs Apple's installer; macOS asks for your password), **Open in Apple's Installer** (the launcher only downloads and verifies), or **Install it yourself…** (a copyable Terminal command). Setup continues as soon as `container` appears. | One choice + macOS admin password, once |
| Linux VM services | `container system start` (the first run downloads Apple's default Linux kernel) | — |
| Game runtime image | `container build` of [`runtime/Containerfile`](runtime/Containerfile): a few minutes the first time, then cached | — |
| Start the game | `container run` with the game folder mounted read-only and the saves folder read-write; the game appears in the window | Press **Play** |

A **Developer blog** tab shows the URR blog index (excerpts and outlines that
link to the full posts on markrjohnsongames.com) while setup runs.

### Game version policy

The launcher is locked to the tested minor version (`Manifest.game` in
[`Manifest.swift`](launcher/Sources/URRCore/Manifest.swift)):

| Player's version vs tested 0.10.4d | Result |
|---|---|
| Identical | Runs |
| Different patch level or letter (0.10.4e, 0.10.5) | Warns, then runs |
| Different minor (0.11.x, 0.9.x) | Explains, offers **Try anyway**; the consent is remembered for that version |
| Different major (1.x) | Refuses |

The version comes from the game's `Readme.txt` (`Version 0.10.4d`), cross-checked
against the exe name (`URR0104d.exe`). Independently of the policy, the runtime
refuses an exe that isn't a PyInstaller build of Python 3.7.

## Licensing and redistribution

* **The game** is © Mark R Johnson. Its `Readme.txt` allows redistributing "the
  binary and all accompanying files, unmodified, provided you do so free of
  charge", with the Readme included. Accordingly:
  * `scripts/make-app.sh --with-game` bundles the official `URR0104d.zip`
    byte-for-byte (sha256-checked; the Readme is inside it). **Only distribute
    such a build free of charge.** Without `--with-game`, players download the ZIP
    themselves from the official site, either in one click or by pointing the launcher at
    the ZIP.
  * The game's bytecode is extracted on the player's own machine, at run time,
    inside the VM. No modified or derived game file is ever distributed, and the
    game folder is mounted read-only.
* **The runtime image** contains only open-source software and no game files.
  It is built locally on the player's Mac, so nothing GPL is redistributed by
  default. See [THIRD_PARTY.md](THIRD_PARTY.md) before publishing a prebuilt image.
* **Apple container** (Apache-2.0) is downloaded from Apple's GitHub release, not
  bundled.

## Repository layout

| Path | What |
|---|---|
| `launcher/` | Swift package: `URRCore` (version policy, ZIP import/download, container driver, setup pipeline), the SwiftUI app `URRLauncher`, the `urrctl` CLI, tests |
| `runtime/` | Linux image: `Containerfile`, `entrypoint.sh` (Xvnc + websockify + game), `web/index.html` (noVNC viewer) |
| `game/` | Python run inside the VM: `extract.py` (pulls the .pyc out of the PyInstaller exe), `urr_container.py` (save-format, renderer and display fixes) |
| `news/` | Developer-blog page: `scrape.py`, `build.py`, `site/` (template + posts.json) |
| `native/` | Alternative backend: the game natively on Intel Python 3.7 under Rosetta (no VM) |
| `scripts/make-app.sh` | Builds `dist/Ultima Ratio Regum.app` |

## Building

Requirements: Xcode command-line tools (Swift 6), Python 3 (for `news/build.py`).

```sh
scripts/make-app.sh               # dist/Ultima Ratio Regum.app (players download the game)
scripts/make-app.sh --with-game   # also bundles the official game ZIP, unmodified
swift test --package-path launcher
```

Set `SIGN_IDENTITY="Developer ID Application: …"` to sign for distribution;
notarization isn't scripted yet. The default ad-hoc signature is fine on the build machine.

### urrctl

The same setup steps from a terminal (built alongside the app, and inside the
app at `Contents/MacOS/urrctl`):

```sh
urrctl doctor              # run the checks; never installs or downloads
urrctl check URR0104d.zip  # what version is this, and would it run?
urrctl import URR0104d.zip # install a game ZIP (--yes accepts an untested minor version)
urrctl play                # set up as needed, then open the game in your browser
```

### Installing and removing Apple container by hand

The command the app's **Install it yourself…** option shows:

```sh
cd ~/Downloads &&
curl -fLO https://github.com/apple/container/releases/download/1.6.1/container-1.6.1-installer-signed.pkg &&
echo "cd47846819f06478d067060efe21e516b562ac0a9af8eecad6d5fea0b556b200  container-1.6.1-installer-signed.pkg" | shasum -a 256 -c - &&
pkgutil --check-signature container-1.6.1-installer-signed.pkg | grep "Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)" &&
sudo installer -pkg container-1.6.1-installer-signed.pkg -target /
```

To uninstall (for example, to re-test first-run setup), use Apple's own script,
which refuses to run while the services are up. `-d` also deletes container's data
(images, including the game runtime image, and the kernel); `-k` keeps it.

```sh
container stop --all; container system stop
/usr/local/bin/uninstall-container.sh -d
```

To make the launcher itself start fresh while keeping saves, also remove
`Game/`, `game.json` and `Downloads/` from `~/Library/Application Support/Ultima Ratio Regum/`.

### Environment overrides

| Variable | Effect |
|---|---|
| `URR_HOME` | Data folder (default `~/Library/Application Support/Ultima Ratio Regum`: `Game/`, `Saves/`, `game.json`) |
| `URR_RESOURCES` | Where `urrctl` finds `runtime/` (default: the enclosing repository) |
| `URR_RUNTIME_IMAGE` | Use this image instead of building one, e.g. a published prebuilt image |
| `URR_DEV_VIEWER_URL` | Development: skip setup and show an already-running viewer |

### Testing the runtime image without `container`

The image is plain OCI, so any OCI runtime can exercise it:

```sh
docker build -t urr-runtime:dev -f runtime/Containerfile .
docker run --rm -p 127.0.0.1:16080:6080 -e URR_GEOMETRY=1512x944 -e URR_VNC_PASSWORD=secret \
  -v "$HOME/Library/Application Support/Ultima Ratio Regum/Game:/opt/urr/game:ro" \
  -v /tmp/urr-saves:/data urr-runtime:dev
# browse to http://127.0.0.1:16080/#password=secret, or:
URR_DEV_VIEWER_URL='http://127.0.0.1:16080/#password=secret' "dist/Ultima Ratio Regum.app/Contents/MacOS/URRLauncher"
```

## How it works

1. `extract.py` reads the PyInstaller archive in `URR0104d.exe` and writes the
   game's main module as a Python 3.7 `.pyc` (cached in `Saves/.runtime/` by the exe's hash).
2. `urr_container.py` runs it as `__main__` (the game's saved worlds reference
   classes as `__main__.<Class>`) after three fixes:
   * forces `dbm.dumb`, so saves keep the Windows format (`World.dat/.dir/.bak`) and move freely between Windows, the VM and the native backend;
   * swaps the game's OpenGL2 renderer for SDL2 (OpenGL2 ignores `keep_aspect`, and in a VM it would be software GL);
   * shrinks the virtual X screen to the game window via RandR, so the view is exactly the game.
3. The game sizes itself from the "screen" resolution: the launcher passes the Mac
   screen's usable size in points, so the game picks the 8/10/12 px font it
   would pick on a real screen. The window then takes the game's exact
   shape, one game pixel per point, so Retina displays show it at a crisp 2×.
4. TigerVNC's `Xvnc` provides the display, protected by a per-launch password
   that never appears on a command line. websockify and noVNC serve it on a port
   published to 127.0.0.1 only, and a WKWebView in the app shows it.

Why these versions: the Windows build freezes Python 3.7 with tcod 11.19.3 and
numpy 1.19.3. tcod 11.19.3 has no linux/arm64 wheel, and its cffi bindings
can't parse SDL ≥ 2.24 headers, so the image builds SDL 2.0.14 from pinned
source on Debian bookworm. Bullseye, which shipped 2.0.14, left the Debian
mirrors in 2026.

## Provenance

This product brings together work from several parallel sessions:

* **Native macOS port** (`ultima-ratio-regum/macos`): bytecode extraction, the
  `dbm.dumb` save fix, the renderer, fullscreen and font-change findings, and the
  Rosetta backend now in `native/`.
* **URR Blog Reader** (`~/Code/urr-blog-reader` @ `ad3ecb4`): scraper and page
  template, now in `news/`; its Claude Artifact publishing pipeline stays in that repo.
* **Container edition** (this repo): runtime image, launcher app, version
  policy, packaging.

## Status

Verified:
* **The full path with Apple container 1.6.1:** installed from the app, `system
  start` with the kernel download, `build` (about 1.5 min), and `run` with
  the 127.0.0.1 publish. The game picked its 10px font for a 1352×817 screen, and
  the display fitted itself to 1060×700.
* The runtime image under docker (arm64), menu input and VNC password enforcement.
* ZIP import and version policy (unit tests plus the real 0.10.4d ZIP).
* The app's setup flow, game view, keyboard input and blog tab.

Not yet verified: the **Open in Apple's Installer** and **Install it yourself**
paths (new), `native/setup.sh` as a whole (its steps follow the native port's
verified recipe), a full play-through with save/load, and notarized distribution.
