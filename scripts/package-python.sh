#!/usr/bin/env bash
# Build the Python wheel (abi3, CPython >= 3.9) into dist/wheels and check that it installs into a
# fresh virtual environment and runs. It does NOT publish. A wheel for PyPI has to be built in a
# manylinux container (or by CI per platform) so its tag is portable; the one built here carries this
# machine's glibc tag.
#
#   scripts/package-python.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Git Bash on Windows has no python3 and a Scripts/ directory where the venv keeps its tools.
PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
VENV=${VENV:-.venv}
if [ -d "$VENV/Scripts" ]; then VBIN=$VENV/Scripts; else VBIN=$VENV/bin; fi
if [ ! -x "$VBIN/maturin" ] && [ ! -x "$VBIN/maturin.exe" ]; then
  "$PY" -m venv "$VENV"
  if [ -d "$VENV/Scripts" ]; then VBIN=$VENV/Scripts; else VBIN=$VENV/bin; fi
  "$VBIN/python" -m pip install --quiet maturin==1.16.0
fi
# shellcheck source=remap-flags.sh
. scripts/remap-flags.sh   # no builder path in the shipped extension module
rm -rf dist/wheels
"$VBIN/maturin" build --locked --release -m crates/pagetriage-py/Cargo.toml -o dist/wheels
WHEEL=$(ls dist/wheels/*.whl)
echo "built $WHEEL ($(wc -c < "$WHEEL" | tr -d ' ') bytes)"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
"$PY" -m venv "$SCRATCH/venv"
if [ -d "$SCRATCH/venv/Scripts" ]; then SBIN=$SCRATCH/venv/Scripts; else SBIN=$SCRATCH/venv/bin; fi
"$SBIN/python" -m pip install --quiet --no-index --no-deps "$WHEEL"
"$SBIN/python" -I - <<'PY'
import json
import pagetriage_py

gray = bytes([255]) * (64 * 64)
out = json.loads(pagetriage_py.analyse_page(gray, 64, 64))
assert any(f["kind"] == "blank_page" for f in out["findings"]), out
try:
    pagetriage_py.analyse_page(b"\x00\x00\x00", 2, 2)
except ValueError:
    pass
else:
    raise SystemExit("an inconsistent buffer did not raise ValueError")
print("python wheel ok:", len(pagetriage_py.schema_json()), "bytes of schema,",
      len(pagetriage_py.params_toml()), "bytes of default params")
PY
