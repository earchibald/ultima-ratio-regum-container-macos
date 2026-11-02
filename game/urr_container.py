"""Run the unmodified Ultima Ratio Regum bytecode inside the Linux runtime image.

Must run on Python 3.7 (the bytecode's version) with tcod 11.19.3, on an X
display (Xvnc, started by entrypoint.sh). Fixes carried over from the native
macOS port, plus one for the virtual display:

1. Save format: the game saves through `shelve` and checks for saves by
   looking for `World.dat`. The Windows build only has `dbm.dumb` (.dat/.dir/
   .bak files); Linux Python would pick `dbm.gnu`. Force `dbm.dumb`, so saves
   stay in the Windows format and can be moved between platforms.
2. Data folder: the game reads fonts and writes saves relative to the current
   directory. Run it from URR_DATA_DIR (a host folder bind-mounted at /data).
3. Renderer: the game asks for RENDERER_OPENGL2 (4), which ignores
   keep_aspect and, in a VM, would mean slow software OpenGL. Use the SDL2
   renderer, and letterbox instead of stretching (libtcod's default).
4. Virtual display: there is no window manager, so the game's window sits on
   a bigger X screen. Shrink the X screen to the window (xrandr), so the VNC
   view — and the Mac window showing it — is exactly the game.

Diagnostics: if the game hangs, dump every thread's Python stack to the
launcher log without stopping it:

    container exec urr-game sh -c 'kill -USR1 $(cat /tmp/urr-game.pid)'
"""
import faulthandler
import os
import runpy
import shutil
import signal
import subprocess
import sys
import warnings

GAME_DIR = os.environ.get("URR_GAME_DIR", "/opt/urr/game")
DATA_DIR = os.environ.get("URR_DATA_DIR", "/data")
FONTS = ("8x8.png", "10x10.png", "12x12.png")
PID_FILE = "/tmp/urr-game.pid"


def log(msg):
    print("urr: %s" % msg, file=sys.stderr, flush=True)


def force_dumb_dbm():
    import dbm
    import dbm.dumb
    dbm._names = ["dbm.dumb"]
    dbm._modules = {"dbm.dumb": dbm.dumb}
    dbm._defaultmod = dbm.dumb


def fit_screen_to_window(tcod):
    """Move the game window to 0,0 and make the X screen exactly its size."""
    window = tcod.lib.TCOD_sys_get_sdl_window()
    if window == tcod.ffi.NULL:
        return
    size = tcod.ffi.new("int[2]")
    tcod.lib.SDL_GetWindowSize(window, size, size + 1)
    w, h = size[0], size[1]
    tcod.lib.SDL_SetWindowPosition(window, 0, 0)
    # Xvnc only switches to sizes its output has a mode for: add one (it may
    # already exist from an earlier font change), select it, then shrink the
    # framebuffer to match.
    mode = "%dx%d" % (w, h)

    def xrandr(*args):
        return subprocess.run(("xrandr",) + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    xrandr("--newmode", mode, "0", str(w), "0", "0", "0", str(h), "0", "0", "0")
    xrandr("--addmode", "VNC-0", mode)
    for step in (("--output", "VNC-0", "--mode", mode), ("--fb", mode)):
        result = xrandr(*step)
        if result.returncode:
            log("could not resize the display to %s: %s" % (mode, result.stdout.decode().strip()))
            return
    log("display fitted to game window %s" % mode)


def patch_display():
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        import libtcodpy
    import tcod

    original_init_root = libtcodpy.console_init_root
    original_flush = libtcodpy.console_flush

    def console_init_root(w, h, title=None, fullscreen=False, renderer=None, *args, **kwargs):
        # Called at start-up and again whenever the Options menu changes the
        # font size (the window is recreated with a new size). The game always
        # passes renderer=4 (OpenGL2) positionally.
        root = original_init_root(w, h, title, fullscreen, libtcodpy.RENDERER_SDL2, *args, **kwargs)
        try:
            fit_screen_to_window(tcod)
        except Exception as e:  # cosmetic; never block the game over it
            log("could not fit the display: %s" % e)
        return root

    def console_flush(*args, **kwargs):
        kwargs.setdefault("keep_aspect", True)
        return original_flush(*args, **kwargs)

    libtcodpy.console_init_root = console_init_root
    libtcodpy.console_flush = console_flush


def install_stack_dump():
    """On SIGUSR1, write all threads' stacks to stderr (the launcher log).

    faulthandler dumps from its C signal handler, so this works even while
    the game is stuck in a pure-Python loop that never yields.
    """
    faulthandler.register(signal.SIGUSR1, file=sys.stderr, all_threads=True)
    with open(PID_FILE, "w") as f:
        f.write("%d\n" % os.getpid())


def enter_data_dir():
    os.makedirs(DATA_DIR, exist_ok=True)
    for font in FONTS:
        dst = os.path.join(DATA_DIR, font)
        if not os.path.exists(dst):
            shutil.copy2(os.path.join(GAME_DIR, font), dst)
    os.chdir(DATA_DIR)


def main(pyc):
    if sys.version_info[:2] != (3, 7):
        raise SystemExit("URR's bytecode requires Python 3.7, not %d.%d" % sys.version_info[:2])
    install_stack_dump()
    force_dumb_dbm()
    patch_display()
    enter_data_dir()
    log("data folder %s" % DATA_DIR)
    # Pickled saves reference classes as __main__.<Name>, so the game must run
    # as __main__, as it did when frozen.
    sys.argv = [pyc]
    runpy.run_path(pyc, run_name="__main__")


if __name__ == "__main__":
    main(sys.argv[1])
