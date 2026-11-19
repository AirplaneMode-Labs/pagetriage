#!/usr/bin/env bash
# Tests for scripts/check-no-builder-paths.sh (fails when a wheel or tgz contains a builder path) and
# for the single-line "Not published yet" sentence that prove-install.sh asserts (BUG-T2-S3-03, -06).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
GATE="$SCRIPTS_DIR/check-no-builder-paths.sh"
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
cd "$SCRATCH"
mkdir -p clean leak1 leak2 leak3 leak4
printf 'fine\n' > clean/a.txt
printf 'built at /Users/someone/x\n' > leak1/a.txt
printf 'built at /home/ci/x\n' > leak2/a.txt
printf 'tmp /private/tmp/y\n' > leak3/a.txt
printf 'nested\n' > leak4/a.txt; python3 -c 'import sys;open("leak4/b.bin","wb").write(b"\x00\x01/Users/x\x00")'
mk() { python3 - "$1" <<'PY'
import sys, zipfile, tarfile, os
d = sys.argv[1]
with zipfile.ZipFile(d + ".whl", "w") as z:
    for f in os.listdir(d): z.write(os.path.join(d, f), f)
with tarfile.open(d + ".tgz", "w:gz") as t:
    for f in os.listdir(d): t.add(os.path.join(d, f), "package/" + f)
PY
}
for d in clean leak1 leak2 leak3 leak4; do mk $d; done
run() { bash "$GATE" "$@" >/dev/null 2>&1; echo $?; }
expect_eq "clean wheel and tgz pass" 0 "$(run clean.whl clean.tgz)"
for d in leak1 leak2 leak3 leak4; do
  expect_eq "$d wheel is refused" 1 "$(run $d.whl)"
  expect_eq "$d tgz is refused" 1 "$(run $d.tgz)"
done

# BUG-T2-S6-05: Windows builder paths (drive letter in either case, either slash, the runner user) are refused too.
mkdir -p w1 w2 w3 w4 w5 w6
python3 - <<'PY'
open("w1/a.bin","wb").write(b"\x00D:\\a\\pagetriage\\src\\lib.rs\x00")
open("w2/a.bin","wb").write(b"\x00C:\\Users\\runneradmin\\.cargo\\registry\x00")
open("w3/a.bin","wb").write(b"\x00c:/users/someone/x\x00")
open("w4/a.bin","wb").write(b"\x00d:/a/pagetriage/pagetriage\x00")
open("w5/a.bin","wb").write(b"\x00path RunnerAdmin here\x00")
open("w6/a.bin","wb").write(b"\x00C:\\USERS\\x\x00")
PY
for d in w1 w2 w3 w4 w5 w6; do mk $d; done
for d in w1 w2 w3 w4 w5 w6; do
  expect_eq "$d (Windows form) wheel is refused" 1 "$(run $d.whl)"
  expect_eq "$d (Windows form) tgz is refused" 1 "$(run $d.tgz)"
done

# BUG-T2-S6-09: JSON-escaped doubled separators, any drive letter, and UTF-16LE forms are refused; look-alikes pass.
mkdir -p x1 x2 x3 x4 x5 x6 x7 g1 g2
python3 - <<'PY'
open("x1/a.json","wb").write(b'{"p":"D:\\\\a\\\\pagetriage\\\\x"}')
open("x2/a.json","wb").write(b'{"p":"C:\\\\Users\\\\bob\\\\.cargo"}')
open("x3/a.bin","wb").write(b"\x00E:\\a\\pagetriage\x00")
open("x4/a.bin","wb").write(b"\x00E:\\Users\\bob\\.cargo\x00")
open("x5/a.bin","wb").write("D:\\a\\pagetriage".encode("utf-16-le"))
open("x6/a.bin","wb").write("C:\\Users\\bob".encode("utf-16-le"))
open("x7/a.bin","wb").write(b'\x00z:/users/bob/x\x00')
open("g1/a.bin","wb").write(b"uuid:/a/ and more")
open("g2/a.bin","wb").write(b"xD:\\a\\ here")
PY
for d in x1 x2 x3 x4 x5 x6 x7 g1 g2; do mk $d; done
for d in x1 x2 x3 x4 x5 x6 x7; do
  expect_eq "$d (S6-09 form) wheel is refused" 1 "$(run $d.whl)"
  expect_eq "$d (S6-09 form) tgz is refused" 1 "$(run $d.tgz)"
done
for d in g1 g2; do
  expect_eq "$d (look-alike) wheel passes" 0 "$(run $d.whl)"
  expect_eq "$d (look-alike) tgz passes" 0 "$(run $d.tgz)"
done
expect_eq "no arguments is a usage error" 2 "$(run)"
# The README sentence is one plain line.
S1='Not published yet: the npm scope @airplanemode and the PyPI and crates.io names are not reserved. The commands below were proven from locally built artifacts on macOS arm64 (an npm pack tarball installed offline into a fresh empty directory, a wheel installed into a fresh venv); publishing to the registries is the owner'"'"'s step.'
if grep -qxF "$S1" "$REPO/README.md"; then ok "README carries the exact sentence on one plain line"; else fail "README lacks the exact one-line sentence"; fi
if grep -qF "$S1" "$SCRIPTS_DIR/prove-install.sh"; then ok "prove-install.sh asserts the full sentence"; else fail "prove-install.sh does not assert the full sentence"; fi
finish
