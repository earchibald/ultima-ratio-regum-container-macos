#!/bin/sh
# Run URR with the bundled Intel Python 3.7 (macOS runs it under Rosetta).
# Python is invoked directly, not via /usr/bin/arch: arch is SIP-protected and
# would strip DYLD_INSERT_LIBRARIES.
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM="$HERE/build/hidpi_shim.dylib"
[ -f "$SHIM" ] && export DYLD_INSERT_LIBRARIES="$SHIM"
exec "$HERE/build/python/install/bin/python3" "$HERE/launcher.py" "$@"
