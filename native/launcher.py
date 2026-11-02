"""macOS launcher for the unmodified Ultima Ratio Regum bytecode.

Must run on Python 3.7 (the bytecode's version) with tcod 11.19.3.
Applies two fixes before handing control to the game:

1. Save format: the game saves through `shelve`, and checks for saves by
   looking for `World.dat`. Windows Python only has `dbm.dumb`, which writes
   .dat/.dir/.bak files; macOS Python would pick `dbm.ndbm` (writes `.db`,
   and corrupts large records - CPython bpo-33074). Force `dbm.dumb`.
2. Data folder: the game reads fonts and writes saves relative to the
   current directory. Run it from a writable per-user folder instead.
   Override with URR_DATA_DIR.
3. Window shape: libtcod stretches the console to fill the window, so a
   free resize distorts the game. Lock the window's aspect ratio (SDL2 has
   no API for this, so it is set on the NSWindow directly), and letterbox
   in fullscreen, where the screen's shape differs from the game's.
4. Fullscreen: the Options menu recreates the window as a window when the
   font size changes; restore fullscreen on the new one.

Retina sharpness comes from hidpi_shim.c, loaded by run.sh.
"""
import ctypes
import ctypes.util
import functools
import os
import runpy
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_HOME = os.path.expanduser("~/Library/Application Support/Ultima Ratio Regum")
# Official game files as installed by the launcher (or urrctl import).
GAME_DIR = os.environ.get("URR_GAME_DIR", os.path.join(DEFAULT_HOME, "Game"))
PYC = os.path.join(HERE, "build", "URR.pyc")
FONTS = ("8x8.png", "10x10.png", "12x12.png")
# Shared with the container backend, so saves work in either.
DEFAULT_DATA_DIR = os.path.join(DEFAULT_HOME, "Saves")


def force_dumb_dbm():
    import dbm
    import dbm.dumb
    dbm._names = ["dbm.dumb"]
    dbm._modules = {"dbm.dumb": dbm.dumb}
    dbm._defaultmod = dbm.dumb


class NSSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


@functools.lru_cache(maxsize=None)
def _objc():
    objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
    ctypes.cdll.LoadLibrary(ctypes.util.find_library("AppKit"))
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    msg_addr = ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value

    @functools.lru_cache(maxsize=None)
    def method(selector, restype, argtypes):
        fn = ctypes.CFUNCTYPE(restype, ctypes.c_void_p, ctypes.c_void_p, *argtypes)(msg_addr)
        return fn, objc.sel_registerName(selector.encode())

    def send(receiver, selector, restype=ctypes.c_void_p, *args):
        fn, sel = method(selector, restype, tuple(type(a) for a in args))
        return fn(receiver, sel, *args)

    return objc, send


NS_WINDOW_STYLE_MASK_FULLSCREEN = 1 << 14


def _ns_windows():
    objc, send = _objc()
    app = send(objc.objc_getClass(b"NSApplication"), "sharedApplication")
    windows = send(app, "windows")
    for i in range(send(windows, "count", ctypes.c_ulong)):
        yield send, send(windows, "objectAtIndex:", ctypes.c_void_p, ctypes.c_ulong(i))


def lock_aspect_ratio(width, height):
    """Make every window of this app keep width:height while being resized."""
    for send, window in _ns_windows():
        send(window, "setContentAspectRatio:", None, NSSize(width, height))


def in_native_fullscreen():
    """True if a window is in macOS (green button) fullscreen."""
    return any(send(window, "styleMask", ctypes.c_ulong) & NS_WINDOW_STYLE_MASK_FULLSCREEN
               for send, window in _ns_windows())


def patch_display(libtcodpy, tcod):
    """Keep the game's shape and fullscreen state as the window is recreated."""
    original_init_root = libtcodpy.console_init_root
    original_flush = libtcodpy.console_flush

    def is_fullscreen():
        try:
            return bool(libtcodpy.console_is_fullscreen()) or in_native_fullscreen()
        except Exception:  # no window yet
            return False

    # Window fixes that macOS can ignore while a window is animating into or
    # out of a fullscreen Space, so they are retried for a few seconds:
    # restoring fullscreen on a recreated window, and resizing a window to the
    # game's shape (after creation, or after leaving fullscreen).
    state = {"shape": None, "was_fullscreen": False,
             "restore_until": 0.0, "fit_until": 0.0, "next_try": 0.0}

    def fit_window():
        """Size the window to the game's shape: native size, or the largest
        that fits the screen. Returns True once the window has that size."""
        ratio_w, ratio_h = state["shape"]
        window = tcod.lib.TCOD_sys_get_sdl_window()
        usable = tcod.ffi.new("SDL_Rect*")
        tcod.lib.SDL_GetDisplayUsableBounds(tcod.lib.SDL_GetWindowDisplayIndex(window), usable)
        border = tcod.ffi.new("int[4]")  # top, left, bottom, right
        if tcod.lib.SDL_GetWindowBordersSize(window, border, border + 1, border + 2, border + 3):
            border[0] = 28  # title bar, if SDL can't tell
        scale = min(1.0, usable.w / ratio_w, (usable.h - border[0]) / ratio_h)
        target_w, target_h = round(ratio_w * scale), round(ratio_h * scale)
        size = tcod.ffi.new("int[2]")
        tcod.lib.SDL_GetWindowSize(window, size, size + 1)
        if abs(size[0] - target_w) <= 1 and abs(size[1] - target_h) <= 1:
            return True
        tcod.lib.SDL_SetWindowSize(window, target_w, target_h)
        return False

    def pending():
        return bool(state["restore_until"] or state["fit_until"])

    def tick():
        if state["shape"] is None:
            return
        now = time.monotonic()
        fullscreen = is_fullscreen()
        if state["was_fullscreen"] and not fullscreen:
            state["fit_until"] = now + 3.0
        state["was_fullscreen"] = fullscreen
        if not pending() or now < state["next_try"]:
            return
        state["next_try"] = now + 0.5
        if state["restore_until"]:
            if fullscreen or now > state["restore_until"]:
                state["restore_until"] = 0.0
            else:
                libtcodpy.console_set_fullscreen(True)
        elif state["fit_until"]:
            if fullscreen or now > state["fit_until"] or fit_window():
                state["fit_until"] = 0.0

    def console_init_root(w, h, title=None, fullscreen=False, renderer=None, *args, **kwargs):
        # The game asks for the OpenGL2 renderer, which ignores keep_aspect
        # (and uses macOS's deprecated OpenGL). The SDL2 renderer draws
        # through Metal and letterboxes properly.
        renderer = libtcodpy.RENDERER_SDL2
        # Changing font size recreates the window, always as a window; carry
        # fullscreen over to the new one.
        was_fullscreen = is_fullscreen()
        root = original_init_root(w, h, title, fullscreen, renderer, *args, **kwargs)
        try:
            # The game's true shape is cells x tile size.
            tile = tcod.ffi.new("int[2]")
            tcod.lib.TCOD_sys_get_char_size(tile, tile + 1)
            state["shape"] = (w * (tile[0] or 1), h * (tile[1] or 1))
            lock_aspect_ratio(*state["shape"])
            now = time.monotonic()
            state.update(was_fullscreen=False, next_try=0.0,
                         fit_until=0.0 if was_fullscreen else now + 3.0,
                         restore_until=now + 6.0 if was_fullscreen else 0.0)
            tick()
        except Exception as e:  # cosmetic; never block the game over it
            print("Could not adjust the game window:", e, file=sys.stderr)
        return root

    def whole_multiple_fills_screen():
        """True if scaling by a whole multiple would still fill (nearly) the
        screen. On a 1698-pixel-high screen 12x12 and 8x8 tiles scale 2.02x
        and 3.03x, but 10x10 tiles scale 2.43x: rounding down to 2x would
        leave a wide border on every side."""
        size = tcod.ffi.new("int[2]")
        if tcod.lib.SDL_GetRendererOutputSize(tcod.lib.TCOD_sys_get_sdl_renderer(), size, size + 1):
            return False
        fit = min(size[0] / state["shape"][0], size[1] / state["shape"][1])
        return fit >= 1 and int(fit) / fit >= 0.9

    def console_flush(*args, **kwargs):
        tick()
        # Letterbox instead of stretching (matters in fullscreen, where the
        # screen's shape differs from the game's); in fullscreen also scale by
        # whole multiples, so every game pixel is the same size, when that
        # doesn't shrink the game much.
        kwargs.setdefault("keep_aspect", True)
        if "integer_scaling" not in kwargs:
            kwargs["integer_scaling"] = (state["shape"] is not None and is_fullscreen()
                                         and whole_multiple_fills_screen())
        return original_flush(*args, **kwargs)

    def console_wait_for_keypress(flush):
        # Menus block here right after a font change; poll instead while a
        # window fix is pending so it isn't stuck until a keypress.
        while pending():
            console_flush()
            key = libtcodpy.console_check_for_keypress(libtcodpy.KEY_PRESSED)
            if key.vk != libtcodpy.KEY_NONE:
                return key
            time.sleep(0.02)
        return original_wait(flush)

    original_wait = libtcodpy.console_wait_for_keypress
    libtcodpy.console_init_root = console_init_root
    libtcodpy.console_flush = console_flush
    libtcodpy.console_wait_for_keypress = console_wait_for_keypress


def patch_window_creation():
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        import libtcodpy
    import tcod
    patch_display(libtcodpy, tcod)


def enter_data_dir():
    data_dir = os.environ.get("URR_DATA_DIR", DEFAULT_DATA_DIR)
    os.makedirs(data_dir, exist_ok=True)
    for font in FONTS:
        dst = os.path.join(data_dir, font)
        if not os.path.exists(dst):
            shutil.copy2(os.path.join(GAME_DIR, font), dst)
    os.chdir(data_dir)
    return data_dir


if __name__ == "__main__":
    if sys.version_info[:2] != (3, 7):
        raise SystemExit("URR's bytecode requires Python 3.7, not %d.%d" % sys.version_info[:2])
    force_dumb_dbm()
    patch_window_creation()
    print("URR data folder:", enter_data_dir(), file=sys.stderr)
    # Pickled saves reference classes as __main__.<Name>, so the game must
    # run as __main__, as it did when frozen.
    sys.argv = [PYC]
    runpy.run_path(PYC, run_name="__main__")
