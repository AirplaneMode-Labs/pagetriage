#!/usr/bin/env bash
# The pagetriage-core NOTICE (BUG-T3-S7-04). pagetriage-core is a published, signed crate (the .crate is in the release manifest), and the
# charter requires LICENSE and NOTICE inside every packed tarball, wheel, sdist and crate. The pagetriage-cli and pagetriage-py crates and the
# npm tarball and the wheel already carry a NOTICE; this crate did not. crates/pagetriage-core/NOTICE must
#   - hold the project notice (the licence choice and the BSD attributions) like the other NOTICE files,
#   - carry a block (name, version, copyright or author line, full MIT text) for every crate of the core crate's tree whose `cargo metadata`
#     licence is exactly "MIT", for ALL targets and with the `pdf` feature on (the build the CLI, the wheel and the WebAssembly package use),
#     computed here from cargo and never hand-kept,
#   - be what scripts/notice-cli.mjs --package pagetriage-core writes, byte for byte (the same generator as the CLI's NOTICE),
#   - end up in the packaged crate (cargo package --list names it).
# The check must fail when one block is removed (mutation step).
#
#   tests/scripts/notice-core.sh                           checks crates/pagetriage-core/NOTICE
#   NOTICE_FILE=<file> tests/scripts/notice-core.sh        checks another file (the red log points it at a missing file)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NOTICE_TXT=${NOTICE_FILE:-$REPO/crates/pagetriage-core/NOTICE}
[ -f "$NOTICE_TXT" ] || { fail "no NOTICE at $NOTICE_TXT (a published crate must carry one)"; finish; exit $?; }

python3 -I - "$TMP/expected.tsv" <<'PY' || { fail "cannot compute the expected crate list"; finish; exit $?; }
import json, re, subprocess, sys
def run(*a): return subprocess.run(["cargo", *a], check=True, capture_output=True, text=True).stdout
tree = run("tree", "--locked", "-p", "pagetriage-core", "--features", "pdf", "--target", "all", "-e", "normal", "--prefix", "none", "-f", "{p}")
inset = set()
for l in tree.splitlines():
    m = re.match(r"(\S+) v(\S+)", l.strip())
    if m: inset.add((m[1], m[2]))
meta = json.loads(run("metadata", "--locked", "--format-version", "1"))
mit = sorted((p["name"], p["version"]) for p in meta["packages"] if (p["name"], p["version"]) in inset and p["license"] == "MIT")
open(sys.argv[1], "w").write("".join(f"{n}\t{v}\n" for n, v in mit))
PY
N=$(wc -l < "$TMP/expected.tsv" | tr -d ' ')
[ "$N" -ge 2 ] && ok "cargo metadata lists $N MIT-only crates in the pagetriage-core tree (pdf feature, all targets)" || fail "too few MIT-only crates found ($N)"
expect_eq "the list holds libm 0.2.16, the MIT-only maths crate core links in every build" 1 "$(grep -cE '^libm	0\.2\.16$' "$TMP/expected.tsv")"
expect_eq "the list holds no crate that only the CLI links (fax, strsim, tiff): the core NOTICE is the core crate's, not the CLI's" 0 "$(grep -cE '^(fax|strsim|tiff)	' "$TMP/expected.tsv")"

check_notice() {
  python3 -I - "$1" "$2" <<'PY'
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
out=$(check_notice "$NOTICE_TXT" "$TMP/expected.tsv") && ok "every MIT-only crate of the core tree has its block (name, version, copyright or author, MIT text)" || { fail "MIT-only crate blocks of the core tree:"; echo "$out" | sed 's/^/        /'; }
grep -q "Airplane Mode Labs pagetriage" "$NOTICE_TXT" && grep -q "MIT OR Apache-2.0\|MIT licence (LICENSE-MIT) or the Apache License" "$NOTICE_TXT" && ok "the core NOTICE states the licence choice (MIT or Apache-2.0, unchanged)" || fail "the core NOTICE lacks the project notice and the licence choice"
grep -q "Copyright (c) 2016 Dropbox, Inc." "$NOTICE_TXT" && ok "the core NOTICE carries the BSD attributions of the root NOTICE" || fail "the core NOTICE lacks the BSD attributions"
expect_eq "the core NOTICE names its own tree (not the CLI's)" 1 "$(grep -c 'Crates in the pagetriage-core crate' "$NOTICE_TXT" | awk '{print ($1>=1)?1:0}')"
expect_eq "AGPL and SSPL are named only in the sentence that says no such code is included" "$(grep -ciE 'AGPL or SSPL code is included' "$NOTICE_TXT")" "$(grep -ciE 'AGPL|SSPL' "$NOTICE_TXT")"

# Mutation: remove one block; the check must now fail.
python3 -I - "$NOTICE_TXT" "$TMP/mutated" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
t2 = re.sub(r"^=== libm 0\.2\.16 \(MIT\) ===\n.*?(?=^=== |\Z)", "", t, flags=re.S | re.M)
open(sys.argv[2], "w", encoding="utf8").write(t2)
PY
if check_notice "$TMP/mutated" "$TMP/expected.tsv" >/dev/null 2>&1; then
  if grep -q '^=== libm 0.2.16' "$NOTICE_TXT"; then fail "the check passes with the libm block removed (the test cannot fail)"; else fail "the file under test has no libm 0.2.16 block"; fi
else ok "the check fails when the libm 0.2.16 block is removed"; fi

if [ -z "${NOTICE_FILE:-}" ]; then
  command -v node >/dev/null || { fail "node not found: scripts/notice-cli.mjs cannot run"; finish; exit $?; }
  if node scripts/notice-cli.mjs --package pagetriage-core "$TMP/generated" >"$TMP/gen.log" 2>&1; then
    cmp -s "$TMP/generated" "$NOTICE_TXT" && ok "scripts/notice-cli.mjs --package pagetriage-core reproduces crates/pagetriage-core/NOTICE byte for byte" || fail "the generator output differs from crates/pagetriage-core/NOTICE (run: node scripts/notice-cli.mjs --package pagetriage-core crates/pagetriage-core/NOTICE)"
  else fail "scripts/notice-cli.mjs --package pagetriage-core failed: $(tail -2 "$TMP/gen.log")"; fi
  node scripts/notice-cli.mjs --package pagetriage-core --check >/dev/null 2>&1 && ok "--check exits 0 on the committed core NOTICE" || fail "--check exits non-zero on the committed core NOTICE"
  node scripts/notice-cli.mjs --package pagetriage-core --check "$TMP/mutated" >/dev/null 2>&1 && fail "--check passes a core NOTICE without the libm block" || ok "--check fails a core NOTICE without the libm block"
  node scripts/notice-cli.mjs --check crates/pagetriage-core/NOTICE >/dev/null 2>&1 && fail "the CLI check passes the core NOTICE (the two files are different)" || ok "the CLI check does not pass the core NOTICE (the two files are different)"
  node scripts/notice-cli.mjs --package pagetriage-py "$TMP/x" >/dev/null 2>&1 && fail "an unknown package is accepted" || ok "an unknown --package is a usage error"
  # the crate tarball would hold the file
  if cargo package --list --locked --allow-dirty -p pagetriage-core > "$TMP/list.txt" 2>"$TMP/list.err"; then
    expect_eq "cargo package --list names NOTICE, LICENSE-APACHE and LICENSE-MIT in pagetriage-core" 3 "$(grep -cxE 'NOTICE|LICENSE-APACHE|LICENSE-MIT' "$TMP/list.txt")"
  else fail "cargo package --list failed: $(tail -2 "$TMP/list.err")"; fi
fi
finish
