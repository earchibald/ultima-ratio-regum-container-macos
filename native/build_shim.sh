#!/bin/sh
# Build build/hidpi_shim.dylib against tcod's bundled SDL2 (x86_64, for Rosetta).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SDL="$HERE/build/python/install/lib/python3.7/site-packages/tcod/.dylibs/SDL2"
OUT="$HERE/build/hidpi_shim.dylib"
clang -arch x86_64 -dynamiclib -O2 -headerpad_max_install_names -o "$OUT" "$HERE/hidpi_shim.c" "$SDL"
# SDL2's install name is a meaningless build path; point at the real file.
install_name_tool -change "$(otool -D "$SDL" | tail -1)" "$SDL" "$OUT"
echo "built $OUT"
