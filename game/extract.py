"""Extract the game's compiled main module from the Windows PyInstaller exe.

Writes a standard Python 3.7 .pyc. Runs on any Python 3; it only parses the
archive, it never executes the code. The extracted file stays on the player's
machine — it is never redistributed.

    python3 extract.py URR0104d.exe out/URR.pyc

Exit status 2 means the exe is not a build this runtime can run (not a
PyInstaller archive, or not frozen with Python 3.7).

Originally written for the native macOS port (ultima-ratio-regum/macos).
"""
import os
import struct
import sys
import zlib

COOKIE = b"MEI\x0c\x0b\x0a\x0b\x0e"
PY37_MAGIC = (3394).to_bytes(2, "little") + b"\r\n"
SUPPORTED_PYVER = 307


class UnsupportedExe(Exception):
    pass


def read_toc(exe):
    pos = exe.rfind(COOKIE)
    if pos < 0:
        raise UnsupportedExe("not a PyInstaller executable")
    pkglen, tocoff, toclen, pyver = struct.unpack("!iiii", exe[pos + 8:pos + 24])
    if pyver != SUPPORTED_PYVER:
        raise UnsupportedExe("expected a Python 3.7 build, got Python %d.%d" % divmod(pyver, 100))
    start = len(exe) - pkglen
    toc = exe[start + tocoff:start + tocoff + toclen]
    entries, p = {}, 0
    while p < len(toc):
        elen, off, clen, _ulen, cflag, typ = struct.unpack("!iiiiBc", toc[p:p + 18])
        name = toc[p + 18:p + elen].rstrip(b"\0").decode()
        entries[name] = (typ.decode(), start + off, clen, cflag)
        p += elen
    return entries


def extract(exe_path, out_path):
    """Write the game's .pyc to out_path; return the frozen script's name."""
    with open(exe_path, "rb") as f:
        exe = f.read()
    entries = read_toc(exe)
    # The game script is the one 's' entry that isn't a PyInstaller bootstrap/runtime hook.
    scripts = [n for n, (t, *_) in entries.items()
               if t == "s" and not n.startswith(("pyiboot", "pyi_rth"))]
    if len(scripts) != 1:
        raise UnsupportedExe("could not identify the game script: %s" % scripts)
    name = scripts[0]
    _, off, clen, cflag = entries[name]
    code = exe[off:off + clen]
    if cflag:
        code = zlib.decompress(code)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "wb") as f:
        # PEP 552 header: magic, flags=0, mtime=0, source size=0
        f.write(PY37_MAGIC + b"\0" * 12 + code)
    os.replace(tmp, out_path)
    return name, len(code)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract.py GAME.exe OUT.pyc")
    try:
        name, size = extract(sys.argv[1], sys.argv[2])
    except UnsupportedExe as e:
        print("extract: %s" % e, file=sys.stderr)
        sys.exit(2)
    print("extract: %s -> %s (%s bytes)" % (name, sys.argv[2], format(size, ",")))


if __name__ == "__main__":
    main()
