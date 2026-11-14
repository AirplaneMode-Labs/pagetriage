#!/usr/bin/env bash
# Fail (exit 1) if any file inside a wheel (.whl) or npm tarball (.tgz) contains a builder path:
# '/Users/', '/home/' or '/private/tmp' (compiler panic-location strings, SBOMs, debug info).
#   scripts/check-no-builder-paths.sh <artifact.whl|artifact.tgz>...
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <wheel-or-tgz>..." >&2; exit 2; }
python3 -I - "$@" <<'PY'
import sys, tarfile, zipfile
NEEDLES = (b"/Users/", b"/home/", b"/private/tmp")
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
if bad:
    print("builder path found:", *bad, sep="\n  ")
    sys.exit(1)
print("no builder path ('/Users/', '/home/', '/private/tmp') in", ", ".join(sys.argv[1:]))
PY
