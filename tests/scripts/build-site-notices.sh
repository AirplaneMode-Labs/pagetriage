#!/usr/bin/env bash
# The demo NOTICE carries a full block (name, version, copyright line or Cargo.toml author, full MIT text)
# for every crate compiled into the WASM build whose `cargo metadata` licence is exactly "MIT" (TD-03,
# BUG-T1-S3-R2-02, BUG-T2-S3-20-R2). The expected crate list is computed here from cargo metadata, never
# hand-kept. The test must fail when one block is removed (mutation step below).
#
#   tests/scripts/build-site-notices.sh                    builds the notices into a temp dir via scripts/build-site.sh
#   NOTICE_FILE=<file> tests/scripts/build-site-notices.sh checks an existing file (used for the red log)
#   PAGETRIAGE_WHEEL=<whl> tests/scripts/build-site-notices.sh  also asserts the wheel lists NOTICE (S1-082)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [ -n "${NOTICE_FILE:-}" ]; then
  NOTICE_TXT=$NOTICE_FILE; SITE=$(dirname "$NOTICE_FILE")
else
  SITE=$TMP/site; mkdir -p "$SITE"
  SITE_NOTICES_ONLY=1 SITE_OUT=$SITE bash "$SCRIPTS_DIR/build-site.sh" >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log"; fail "build-site.sh (notices only) failed"; }
  NOTICE_TXT=$SITE/NOTICE.txt
fi
[ -f "$NOTICE_TXT" ] || { fail "no NOTICE.txt at $NOTICE_TXT"; finish; exit $?; }

# Expected MIT-only crates, from cargo: "name version author-or-copyright-needle" lines.
python3 -I - "$TMP/expected.tsv" "$TMP/expected-py.tsv" <<'PY' || { fail "cannot compute the expected crate list"; finish; exit $?; }
import json, re, subprocess, sys
def run(*a): return subprocess.run(["cargo", *a], check=True, capture_output=True, text=True).stdout
tree = run("tree","--locked","-p","pagetriage-wasm","--target","wasm32-unknown-unknown","--features","pdf","-e","normal","--prefix","none","-f","{p}")
inTree = set()
for l in tree.splitlines():
    m = re.match(r"(\S+) v(\S+)", l.strip())
    if m: inTree.add((m[1], m[2]))
meta = json.loads(run("metadata","--locked","--format-version","1"))
rows = sorted((p["name"], p["version"]) for p in meta["packages"] if (p["name"], p["version"]) in inTree and p["license"] == "MIT")
open(sys.argv[1], "w").write("".join(f"{n}\t{v}\n" for n, v in rows))
# The Python wheel tree (TD-28): every MIT-only crate of `cargo tree -p pagetriage-py` too.
tree = run("tree","--locked","-p","pagetriage-py","-e","normal","--prefix","none","-f","{p}")
inTree = set()
for l in tree.splitlines():
    m = re.match(r"(\S+) v(\S+)", l.strip())
    if m: inTree.add((m[1], m[2]))
rows = sorted((p["name"], p["version"]) for p in meta["packages"] if (p["name"], p["version"]) in inTree and p["license"] == "MIT")
open(sys.argv[2], "w").write("".join(f"{n}\t{v}\n" for n, v in rows))
PY
N=$(wc -l < "$TMP/expected.tsv" | tr -d ' ')
[ "$N" -ge 1 ] && ok "cargo metadata lists $N MIT-only crates in the WASM tree" || fail "no MIT-only crates found"

# check_notice <file>: every expected crate has a block with a copyright or author line and the MIT text.
check_notice() {
  python3 -I - "$1" "${2:-$TMP/expected.tsv}" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf8").read()
bad = []
for row in open(sys.argv[2]):
    n, v = row.rstrip("\n").split("\t")
    m = re.search(r"^=== " + re.escape(n) + " " + re.escape(v) + r" \(MIT\) ===\n(.*?)(?=^=== |\Z)", text, re.S | re.M)
    if not m: bad.append(f"{n} {v}: block missing"); continue
    b = m[1]
    first = b.strip().split("\n")[0]
    if not (re.match(r"Copyright", first) or first.startswith("author from Cargo.toml:")): bad.append(f"{n} {v}: no copyright or author line")
    if "Permission is hereby granted, free of charge" not in b or "THE SOFTWARE IS PROVIDED" not in b: bad.append(f"{n} {v}: MIT text incomplete")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
}
out=$(check_notice "$NOTICE_TXT") && ok "every MIT-only crate has its block (name, version, copyright or author, MIT text)" || fail "MIT-only crate blocks: $out"

# The repository NOTICE is included, and the licence texts sit next to it.
grep -q "Airplane Mode Labs pagetriage" "$NOTICE_TXT" && grep -q "Copyright (c) 2016 Dropbox, Inc." "$NOTICE_TXT" && ok "demo NOTICE contains the repository NOTICE" || fail "demo NOTICE lacks the repository NOTICE"
for f in LICENSE-MIT LICENSE-APACHE; do
  P=$SITE/$f.txt
  [ -f "$P" ] && cmp -s "$P" "$REPO/$f" && ok "$f served next to the NOTICE equals the root file" || fail "$f.txt next to the demo NOTICE missing or differs"
done

# alloc-stdlib attribution (TD-04): author, repository, and the upstream commit SHA that was read.
grep -q "danielrh@dropbox.com" "$REPO/NOTICE" && grep -q "github.com/dropbox/rust-alloc-no-stdlib" "$REPO/NOTICE" && grep -Eq "upstream commit [0-9a-f]{40}" "$REPO/NOTICE" && ok "NOTICE names the alloc-stdlib author, repository and a 40-hex upstream commit" || fail "NOTICE alloc-stdlib paragraph incomplete"

# Root NOTICE (and so the wheel and crates/pagetriage-py/NOTICE) carries the blocks for the pagetriage-py tree (TD-28).
NP=$(wc -l < "$TMP/expected-py.tsv" | tr -d ' ')
[ "$NP" -ge 1 ] && ok "cargo metadata lists $NP MIT-only crates in the pagetriage-py tree" || fail "no MIT-only crates in the pagetriage-py tree"
out=$(check_notice "$REPO/NOTICE" "$TMP/expected-py.tsv") && ok "root NOTICE has a block for every MIT-only crate of the pagetriage-py tree" || fail "root NOTICE py-tree blocks: $out"

# The SERVED NOTICE.txt carries the 40-hex upstream SHA and every BSD crate attribution (TD-04, BUG-T2-S4-08).
grep -Eq "upstream commit 3b341ccf[0-9a-f]{28}77f1" "$NOTICE_TXT" && ok "served NOTICE.txt carries the upstream SHA 3b341ccf...c077f1" || fail "served NOTICE.txt lacks the upstream SHA"
for c in alloc-no-stdlib alloc-stdlib brotli-decompressor; do
  grep -q "$c" "$NOTICE_TXT" && ok "served NOTICE.txt names $c" || fail "served NOTICE.txt does not name $c"
done
grep -q "brotli-decompressor 5.0.3" "$REPO/NOTICE" && ok "root NOTICE names brotli-decompressor 5.0.3" || fail "root NOTICE does not name brotli-decompressor 5.0.3"

# Mutation: remove one crate block; the check must now fail.
FIRST=$(head -1 "$TMP/expected.tsv" | cut -f1)
python3 -I - "$NOTICE_TXT" "$TMP/mutant.txt" "$FIRST" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
t = re.sub(r"^=== " + re.escape(sys.argv[3]) + r" \S+ \(MIT\) ===\n.*?(?=^=== |\Z)", "", t, count=1, flags=re.S | re.M)
open(sys.argv[2], "w", encoding="utf8").write(t)
PY
if check_notice "$TMP/mutant.txt" >/dev/null 2>&1; then fail "mutation (block for $FIRST removed) was NOT detected"; else ok "mutation (block for $FIRST removed) is detected"; fi
FIRSTP=$(head -1 "$TMP/expected-py.tsv" | cut -f1)
python3 -I - "$REPO/NOTICE" "$TMP/mutant-py.txt" "$FIRSTP" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
t = re.sub(r"^=== " + re.escape(sys.argv[3]) + r" \S+ \(MIT\) ===\n.*?(?=^=== |\Z)", "", t, count=1, flags=re.S | re.M)
open(sys.argv[2], "w", encoding="utf8").write(t)
PY
if check_notice "$TMP/mutant-py.txt" "$TMP/expected-py.tsv" >/dev/null 2>&1; then fail "mutation (root NOTICE block for $FIRSTP removed) was NOT detected"; else ok "mutation (root NOTICE block for $FIRSTP removed) is detected"; fi
# Mutation: the SHA removed from the served NOTICE must be detected.
sed 's/3b341ccf[0-9a-f]*/0000/' "$NOTICE_TXT" > "$TMP/mutant-sha.txt"
if grep -Eq "upstream commit 3b341ccf[0-9a-f]{28}77f1" "$TMP/mutant-sha.txt"; then fail "mutation (SHA removed) was NOT detected"; else ok "mutation (SHA removed) is detected"; fi

# Wheel carries NOTICE (S1-082).
grep -q '"NOTICE"' crates/pagetriage-py/pyproject.toml && cmp -s NOTICE crates/pagetriage-py/NOTICE && ok "pyproject license-files lists NOTICE and the crate copy equals the root NOTICE" || fail "pyproject license-files lacks NOTICE or crates/pagetriage-py/NOTICE differs from root"
if [ -n "${PAGETRIAGE_WHEEL:-}" ]; then
  unzip -l "$PAGETRIAGE_WHEEL" | gq "dist-info/licenses/NOTICE" && ok "wheel lists dist-info/licenses/NOTICE" || fail "wheel does not list NOTICE"
  WN=$(unzip -Z1 "$PAGETRIAGE_WHEEL" | grep "dist-info/licenses/NOTICE$" | head -1)
  unzip -p "$PAGETRIAGE_WHEEL" "$WN" > "$TMP/wheel-NOTICE" 2>/dev/null
  out=$(check_notice "$TMP/wheel-NOTICE" "$TMP/expected-py.tsv") && ok "wheel NOTICE carries every MIT-only crate block of the pagetriage-py tree" || fail "wheel NOTICE blocks: $out"
else
  echo "not applicable: no wheel in this job (PAGETRIAGE_WHEEL unset; wheels are Sprint 6, TD-09; set PAGETRIAGE_WHEEL=<whl>; built with: uvx maturin build --release --locked -m crates/pagetriage-py/Cargo.toml)"
fi
finish
