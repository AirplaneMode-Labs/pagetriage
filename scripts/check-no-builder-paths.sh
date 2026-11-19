#!/usr/bin/env bash
# Fail (exit 1) if any file inside a wheel (.whl) or npm tarball (.tgz) contains a builder path:
# '/Users/', '/home/' or '/private/tmp' (compiler panic-location strings, SBOMs, debug info), or a Windows builder
# path: '<any drive>:\\Users\\', '<any drive>:/Users/', '<any drive>:\\a\\', '<any drive>:/a/' (separators single or doubled, UTF-16LE too; drive letter in either case, not preceded by a letter or digit)
# or 'runneradmin' (case-insensitive) (BUG-T2-S6-05).
#   scripts/check-no-builder-paths.sh <artifact.whl|artifact.tgz>...
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <wheel-or-tgz>..." >&2; exit 2; }
python3 -I - "$@" <<'PY'
import re, sys, tarfile, zipfile
NEEDLES = (b"/Users/", b"/home/", b"/private/tmp")
# Separators may be doubled (JSON-escaped backslashes); any drive letter A-Z, either case (BUG-T2-S6-09).
WIN_SRC = r"(?<![A-Za-z0-9])(?:[a-z]:[\\/]{1,2}users[\\/]{1,2}|[a-z]:[\\/]{1,2}a[\\/]{1,2})|runneradmin"
WIN = re.compile(WIN_SRC.encode(), re.IGNORECASE)
WIN16 = re.compile(WIN_SRC, re.IGNORECASE)
bad = []
for a in sys.argv[1:]:
    if a.endswith((".whl", ".zip")):
        with zipfile.ZipFile(a) as z:
            items = [(i.filename, z.read(i)) for i in z.infolist() if not i.filename.endswith("/")]
    else:
        with tarfile.open(a) as t:
            items = [(m.name, t.extractfile(m).read()) for m in t.getmembers() if m.isfile()]
    for name, data in items:
        for n in NEEDLES:
            if n in data:
                bad.append(f"{a}: {name} contains {n.decode()}")
        m = WIN.search(data)
        if m:
            bad.append(f"{a}: {name} contains a Windows builder path ({m.group(0).decode()})")
        elif b"\x00" in data:
            # UTF-16LE form: decode at both byte alignments and scan the text, for the Windows and POSIX needles.
            for off in (0, 1):
                text = data[off:len(data) - ((len(data) - off) % 2)].decode("utf-16-le", "replace")
                m16 = WIN16.search(text)
                if m16:
                    bad.append(f"{a}: {name} contains a UTF-16LE Windows builder path ({m16.group(0)})")
                    break
                hit = next((n for n in NEEDLES if n.decode() in text), None)
                if hit:
                    bad.append(f"{a}: {name} contains UTF-16LE {hit.decode()}")
                    break
if bad:
    print("builder path found:", *bad, sep="\n  ")
    sys.exit(1)
print("no builder path ('/Users/', '/home/', '/private/tmp', Windows C:\\Users, D:\\a, runneradmin) in", ", ".join(sys.argv[1:]))
PY
