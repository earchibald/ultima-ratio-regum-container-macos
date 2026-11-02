#!/bin/sh
# Set up the native (Rosetta) backend in native/build/:
#   - Intel Python 3.7.9 from python-build-standalone (there is no arm64 3.7)
#   - pip 24.0 (pip 20.2 mis-parses the macOS 27 platform tag), then the exact
#     versions frozen into the Windows build: tcod 11.19.3, numpy 1.19.3
#   - the game's bytecode, extracted from the installed URR*.exe
#   - the Retina shim (build_shim.sh)
#
# Game files come from the launcher's install (URR_GAME_DIR, default
# ~/Library/Application Support/Ultima Ratio Regum/Game); install the game with
# the app or `urrctl import URR0104d.zip` first. Then run ./run.sh.
#
# Recipe from the native macOS port (ultima-ratio-regum/macos).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
GAME_DIR="${URR_GAME_DIR:-$HOME/Library/Application Support/Ultima Ratio Regum/Game}"
PY_URL=https://github.com/indygreg/python-build-standalone/releases/download/20200823/cpython-3.7.9-x86_64-apple-darwin-pgo-20200823T2228.tar.zst
PY_SHA256=53657e7712cc7b24491fb1fc66dcc8f47a577fc77df137178746987ba4c5afb8

mkdir -p "$BUILD"
PY="$BUILD/python/install/bin/python3"
if [ ! -x "$PY" ]; then
    echo "==> Downloading Intel Python 3.7.9"
    curl -fL --progress-bar -o "$BUILD/python.tar.zst" "$PY_URL"
    echo "$PY_SHA256  $BUILD/python.tar.zst" | shasum -a 256 -c -
    tar -xf "$BUILD/python.tar.zst" -C "$BUILD"
    rm "$BUILD/python.tar.zst"
fi

echo "==> Installing tcod 11.19.3 and numpy 1.19.3"
"$PY" -m pip install --quiet --disable-pip-version-check "pip==24.0"
"$PY" -m pip install --quiet --only-binary=:all: "tcod==11.19.3" "numpy==1.19.3"
"$PY" -c "import tcod, numpy; print('tcod', tcod.__version__, 'numpy', numpy.__version__)"

echo "==> Extracting the game's bytecode"
set -- "$GAME_DIR"/URR*.exe
[ -f "$1" ] || { echo "No URR*.exe in $GAME_DIR; install the game first." >&2; exit 1; }
"$PY" "$HERE/../game/extract.py" "$1" "$BUILD/URR.pyc"

echo "==> Building the Retina shim"
"$HERE/build_shim.sh"
echo "Ready: $HERE/run.sh"
