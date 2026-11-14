#!/usr/bin/env bash
# Prove "installable from a clean machine" from LOCALLY BUILT artifacts, offline, with a real call each:
#   - the wheel into a `python3 -m venv` (pip --no-index --no-deps) and into a `uv venv` (uv pip --offline);
#   - the npm tarball into a fresh empty directory (npm i --ignore-scripts --offline, empty cache).
# Each call analyses the synthetic golden page tests/golden/inputs/blank_speckle.pgm and requires output
# byte-equal to tests/golden/expected/blank_speckle.json. Nothing is published; no network is used.
#
#   scripts/prove-install.sh <wheel.whl> <pagetriage-x.y.z.tgz> <scratch-dir>
#
# <scratch-dir> must not exist yet (it is created, never deleted). Build the artifacts first:
#   RUSTFLAGS="$(. scripts/remap-flags.sh; echo $RUSTFLAGS)" uvx maturin build --release -m crates/pagetriage-py/Cargo.toml -o <wheels-dir>
#   scripts/build-wasm.sh && scripts/package-npm.sh        # -> dist/npm/pagetriage-x.y.z.tgz
set -euo pipefail
[ "$#" -eq 3 ] || { echo "usage: $0 <wheel.whl> <tarball.tgz> <scratch-dir>" >&2; exit 2; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
WHEEL=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
TGZ=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
S=$3
[ ! -e "$S" ] || { echo "error: $S already exists; pick a fresh directory" >&2; exit 2; }
mkdir -p "$S"
S=$(cd "$S" && pwd)
export GOLDEN_IN="$REPO/tests/golden/inputs/blank_speckle.pgm"
export GOLDEN_OUT="$REPO/tests/golden/expected/blank_speckle.json"

echo "wheel file:     $(basename "$WHEEL")"
echo "platform tag:   $(basename "$WHEEL" .whl | awk -F- '{print $NF}') (python/abi tag: $(basename "$WHEEL" .whl | awk -F- '{print $(NF-2) "-" $(NF-1)}'))"
echo "host:           $(uname -sm)"

PYCALL='
import hashlib, json, os, pathlib, sys
import pagetriage_py
data = pathlib.Path(os.environ["GOLDEN_IN"]).read_bytes()
tok, pos = [], 0
while len(tok) < 4:
    while data[pos:pos+1].isspace(): pos += 1
    s = pos
    while not data[pos:pos+1].isspace(): pos += 1
    tok.append(data[s:pos].decode())
pos += 1
w, h = int(tok[1]), int(tok[2])
gray = data[pos:]
out = pagetriage_py.analyse_page(gray, w, h, 150, None, None, "{\"debug\":true}") + "\n"
want = pathlib.Path(os.environ["GOLDEN_OUT"]).read_text(encoding="utf-8")
assert out == want, "output differs from the golden report"
print("real call byte-equal to golden: sha256=" + hashlib.sha256(out.encode()).hexdigest()[:16], "len", len(out), "module", pagetriage_py.__file__)
'

echo "== pip: python3 -m venv + pip install --no-index --no-deps"
python3 -m venv "$S/pipvenv"
"$S/pipvenv/bin/pip" install --no-index --no-deps --disable-pip-version-check "$WHEEL" 2>&1 | tail -2
"$S/pipvenv/bin/python" -I -c "$PYCALL"

echo "== uv: uv venv + uv pip install --offline --no-index --no-deps"
uv venv --quiet "$S/venv"
uv pip install --offline --no-index --no-deps --python "$S/venv/bin/python" "$WHEEL" 2>&1 | tail -3
"$S/venv/bin/python" -I -c "$PYCALL"

echo "== npm: fresh empty directory, npm i <tgz> --ignore-scripts --offline, empty cache"
mkdir -p "$S/npm-fresh" "$S/npm-cache-empty"
( cd "$S/npm-fresh" && npm init -y >/dev/null \
  && npm i "$TGZ" --ignore-scripts --offline --no-audit --no-fund --cache "$S/npm-cache-empty" 2>&1 | tail -3 \
  && echo "-- npm ls --all" && npm ls --all \
  && test "$(ls node_modules | tr '\n' ' ')" = "pagetriage " && echo "node_modules holds exactly: pagetriage" \
  && node -e '
const fs = require("fs"), crypto = require("crypto");
const wasm = require("pagetriage");
const data = fs.readFileSync(process.env.GOLDEN_IN);
let pos = 0; const tok = [];
const sp = (b) => b === 0x20 || (b >= 0x09 && b <= 0x0d);
while (tok.length < 4) { while (sp(data[pos])) pos++; const s = pos; while (!sp(data[pos])) pos++; tok.push(data.subarray(s, pos).toString("ascii")); }
pos++;
const w = Number(tok[1]), h = Number(tok[2]);
const out = wasm.analyse_page(new Uint8Array(data.subarray(pos)), undefined, w, h, 150, undefined, "{\"debug\":true}") + "\n";
if (out !== fs.readFileSync(process.env.GOLDEN_OUT, "utf8")) throw new Error("output differs from the golden report");
console.log("real call byte-equal to golden: sha256=" + crypto.createHash("sha256").update(out).digest("hex").slice(0, 16), "version", wasm.version());
' )

echo "== archive contents check"
python3 - "$WHEEL" "$TGZ" <<'PY'
import sys, tarfile, zipfile
wheel, tgz = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(wheel) as z:
    wheel_files = [(i.filename, i.file_size) for i in z.infolist()]
    readme = [n for n, _ in wheel_files if n.endswith("METADATA")]
    meta = z.read(readme[0]).decode()
with tarfile.open(tgz) as t:
    tgz_files = [(m.name, m.size) for m in t.getmembers() if m.isfile()]
    pkg = t.extractfile("package/package.json").read().decode()
    readme_txt = t.extractfile("package/README.md").read().decode()
import json
SENT = "Not published yet: the npm scope @airplanemode and the PyPI and crates.io names are not reserved. The commands below were proven from locally built artifacts on macOS arm64 (an npm pack tarball installed offline into a fresh empty directory, a wheel installed into a fresh venv); publishing to the registries is the owner's step."
def bad(files):
    return [n for n, s in files if s > 5_000_000 or any(x in n for x in ("tests/", "golden", ".map", ".onnx", "node_modules"))]
for label, files in (("wheel", wheel_files), ("tarball", tgz_files)):
    names = [n for n, _ in files]
    print(label, len(files), "files; largest", max(s for _, s in files), "bytes")
    assert not bad(files), bad(files)
    assert any(n.endswith("LICENSE-MIT") for n in names) and any(n.endswith("LICENSE-APACHE") for n in names), "licence files missing"
assert "scripts" not in json.loads(pkg), "npm package.json has lifecycle scripts"
assert SENT in meta and "not tagged" in meta, "wheel README lacks the honest sentence"
assert SENT in readme_txt and "not tagged" in readme_txt, "tarball README lacks the honest sentence"
print("licence files present, no test data/source maps/model files, nothing over 5 MB, no lifecycle scripts, honest sentence in both READMEs")
PY
echo "== no builder path in the archives"
"$REPO/scripts/check-no-builder-paths.sh" "$WHEEL" "$TGZ"
echo "ALL OK"
