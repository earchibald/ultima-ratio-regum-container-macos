# Third-party software

## Ultima Ratio Regum (the game)

© 2011–2026 Mark R Johnson. Not part of this repository. Its `Readme.txt` grants:

> you may redistribute the binary and all accompanying files, unmodified,
> provided you do so free of charge. This file must be included in any redistribution.

The launcher only ever installs the official ZIP's contents unmodified, mounts
them read-only, and extracts bytecode at run time on the player's machine.
A `--with-game` app build carries the official ZIP byte-for-byte (Readme
included) and must be distributed free of charge.

## Downloaded at run time (not redistributed)

| Component | License | Source |
|---|---|---|
| Apple container 1.6.1 | Apache-2.0 | github.com/apple/container (signed installer pkg) |
| Apple's default Linux kernel for container | GPL-2.0 | installed by `container system start` |

## In the runtime image (built locally from these sources)

| Component | Version | License |
|---|---|---|
| Debian bookworm base (`python:3.7-slim-bookworm`) | — | various (Debian) |
| CPython | 3.7.17 | PSF-2.0 |
| tcod (python-tcod, includes libtcod) | 11.19.3 | BSD-2-Clause |
| numpy | 1.19.3 | BSD-3-Clause |
| cffi / pycparser | 1.15.1 / 2.21 | MIT / BSD-3-Clause |
| SDL | 2.0.14 (source, sha256-pinned) | zlib |
| TigerVNC (`Xvnc`, `vncpasswd`) | 1.12 (Debian) | GPL-2.0-or-later |
| noVNC | 1.3.0 (Debian) | MPL-2.0 |
| websockify | 0.10 (Debian) | LGPL-3.0 |
| x11-xserver-utils (`xrandr`) | Debian | MIT/X11 |

Because the image is built on the player's machine, this project does not
redistribute these binaries. **If you publish a prebuilt image** (for use with
`URR_RUNTIME_IMAGE`), you are redistributing GPL/LGPL/MPL binaries: publish
the corresponding sources or a written offer as those licenses require
(Debian source packages plus the pinned SDL tarball cover this). Never put
game files in a published image.

## In the launcher app

| Component | License | Notes |
|---|---|---|
| URR Blog Reader page (`news/`) | — | Shows titles, dates, section outlines and short excerpts of markrjohnsongames.com posts and links to the originals. Keep it to excerpts. Fonts load from Google Fonts (OFL) when online. |
