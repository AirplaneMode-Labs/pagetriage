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
expect_eq "no arguments is a usage error" 2 "$(run)"
# The README sentence is one plain line.
S1='Not published yet: the npm scope @airplanemode and the PyPI and crates.io names are not reserved. The commands below were proven from locally built artifacts on macOS arm64 (an npm pack tarball installed offline into a fresh empty directory, a wheel installed into a fresh venv); publishing to the registries is the owner'"'"'s step.'
if grep -qxF "$S1" "$REPO/README.md"; then ok "README carries the exact sentence on one plain line"; else fail "README lacks the exact one-line sentence"; fi
if grep -qF "$S1" "$SCRIPTS_DIR/prove-install.sh"; then ok "prove-install.sh asserts the full sentence"; else fail "prove-install.sh does not assert the full sentence"; fi
finish
