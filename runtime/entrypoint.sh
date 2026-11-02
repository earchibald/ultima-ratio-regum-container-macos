#!/bin/sh
# Container entrypoint: virtual display + browser bridge + the game.
#
#   URR_GAME_DIR      official game folder, read-only (must hold exactly one URR*.exe)
#   URR_DATA_DIR      writable saves folder (host bind mount)
#   URR_GEOMETRY      initial virtual screen size, WxH; the game sizes its
#                     window from this, as it would from a real screen
#   URR_VNC_PASSWORD  optional per-launch password the viewer must present
#
# Every step prints a "urr: step ..." line; the Mac launcher shows these.
set -eu

say() { echo "urr: $*" >&2; }

GAME_DIR=${URR_GAME_DIR:-/opt/urr/game}
DATA_DIR=${URR_DATA_DIR:-/data}
GEOMETRY=${URR_GEOMETRY:-1280x800}
RUNTIME=/opt/urr/runtime

set -- "$GAME_DIR"/URR*.exe
if [ ! -f "$1" ] || [ $# -ne 1 ]; then
    say "error: expected exactly one URR*.exe in $GAME_DIR"
    exit 64
fi
EXE=$1

# The bytecode is extracted on the player's machine at run time and cached by
# the exe's hash, so a new game version gets a fresh copy.
say "step extract: reading $(basename "$EXE")"
mkdir -p "$DATA_DIR/.runtime"
SUM=$(sha256sum "$EXE" | cut -c1-16)
PYC="$DATA_DIR/.runtime/URR-$SUM.pyc"
if [ ! -f "$PYC" ]; then
    rm -f "$DATA_DIR"/.runtime/URR-*.pyc
    python3 "$RUNTIME/extract.py" "$EXE" "$PYC" || exit $?
else
    say "extract: using cached $(basename "$PYC")"
fi

say "step display: starting virtual display $GEOMETRY"
mkdir -p /tmp/urr
if [ -n "${URR_VNC_PASSWORD:-}" ]; then
    printf '%s\n' "$URR_VNC_PASSWORD" | vncpasswd -f > /tmp/urr/passwd
    chmod 600 /tmp/urr/passwd
    AUTH="-SecurityTypes VncAuth -rfbauth /tmp/urr/passwd"
else
    AUTH="-SecurityTypes None"
fi
# shellcheck disable=SC2086
Xvnc :1 -geometry "$GEOMETRY" -depth 24 -localhost -rfbport 5900 \
    -AlwaysShared -AcceptSetDesktopSize=0 $AUTH >/tmp/urr/xvnc.log 2>&1 &
XVNC=$!
i=0
until [ -S /tmp/.X11-unix/X1 ]; do
    i=$((i + 1))
    if [ $i -gt 100 ] || ! kill -0 $XVNC 2>/dev/null; then
        say "error: virtual display did not start"; cat /tmp/urr/xvnc.log >&2; exit 70
    fi
    sleep 0.1
done

say "step bridge: serving viewer on :6080"
websockify --web /opt/urr/web 6080 localhost:5900 >/tmp/urr/websockify.log 2>&1 &
BRIDGE=$!

cleanup() { kill $BRIDGE $XVNC 2>/dev/null || true; }
trap cleanup EXIT INT TERM

say "step game: starting Ultima Ratio Regum"
set +e
DISPLAY=:1 python3 "$RUNTIME/urr_container.py" "$PYC"
status=$?
say "game exited with status $status"
exit $status
