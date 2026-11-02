# Native backend (Rosetta, no VM)

The game run directly on macOS with Intel Python 3.7 under Rosetta: an
alternative to the container runtime for Macs where a VM isn't wanted. It comes
from the native macOS port (`ultima-ratio-regum/macos`) and is not yet wired
into the launcher app.

```sh
../launcher/.build/release/urrctl import ~/Downloads/URR0104d.zip   # once: install the game files
./setup.sh    # Intel Python 3.7.9 + tcod 11.19.3 + numpy 1.19.3, bytecode, Retina shim
./run.sh
```

It shares the launcher's folders: game files from `…/Ultima Ratio Regum/Game`
(`URR_GAME_DIR`), saves in `…/Ultima Ratio Regum/Saves` (`URR_DATA_DIR`), so
saves move between this and the container backend.

What `launcher.py` fixes, beyond the container runner's shared fixes (dbm.dumb
saves, SDL2 renderer):

* **Retina:** libtcod creates its SDL window without `SDL_WINDOW_ALLOW_HIGHDPI`.
  `hidpi_shim.c`, loaded through `DYLD_INSERT_LIBRARIES`, interposes
  `SDL_CreateWindow` and adds the flag. Run Python directly, not through
  `/usr/bin/arch`: SIP strips `DYLD_*` from protected binaries.
* **Window shape:** the window's aspect ratio is locked through the NSWindow.
  The view letterboxes, and uses integer scaling in fullscreen only when a whole
  multiple fills at least 90% of the screen.
* **Fullscreen across font changes:** the Options menu recreates the window as
  a window. The fix restores fullscreen, retrying while macOS finishes the Space
  animation, and re-fits the window when leaving fullscreen.
