#!/usr/bin/env bash
# The pagetriage-cli NOTICE (BUG-T3-S4-19, BUG-T3-S4-21): a CLI binary is a copy of every crate linked into it, and MIT
# requires its notice in every copy. crates/pagetriage-cli/NOTICE must carry a block (name, version, copyright or author
# line, full MIT text) for every crate of the CLI tree whose `cargo metadata` licence is exactly "MIT", and the tree is the
# one for ALL targets, because a binary built on Linux or Windows links crates that a macOS build does not (crunchy 0.2.4 is
# one: it is MIT-only, it is only in the tree with `--target all`, and the first generator missed it). The expected list is
# computed here from cargo, never hand-kept. The test must fail when one block is removed (mutation step below), and the
# generator (scripts/notice-cli.mjs) must reproduce the committed file byte for byte.
#
#   tests/scripts/notice-cli.sh                           checks crates/pagetriage-cli/NOTICE
#   NOTICE_FILE=<file> tests/scripts/notice-cli.sh        checks another file (the red log uses the old root NOTICE)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

NOTICE_TXT=${NOTICE_FILE:-$REPO/crates/pagetriage-cli/NOTICE}
[ -f "$NOTICE_TXT" ] || { fail "no NOTICE at $NOTICE_TXT"; finish; exit $?; }

python3 -I - "$TMP/expected.tsv" "$TMP/expected-host.tsv" <<'PY' || { fail "cannot compute the expected crate list"; finish; exit $?; }
import json, re, subprocess, sys
def run(*a): return subprocess.run(["cargo", *a], check=True, capture_output=True, text=True).stdout
def tree_set(*extra):
    tree = run("tree", "--locked", "-p", "pagetriage-cli", *extra, "-e", "normal", "--prefix", "none", "-f", "{p}")
    s = set()
    for l in tree.splitlines():
        m = re.match(r"(\S+) v(\S+)", l.strip())
        if m: s.add((m[1], m[2]))
    return s
meta = json.loads(run("metadata", "--locked", "--format-version", "1"))
def mit(s): return sorted((p["name"], p["version"]) for p in meta["packages"] if (p["name"], p["version"]) in s and p["license"] == "MIT")
open(sys.argv[1], "w").write("".join(f"{n}\t{v}\n" for n, v in mit(tree_set("--target", "all"))))
open(sys.argv[2], "w").write("".join(f"{n}\t{v}\n" for n, v in mit(tree_set())))
PY
N=$(wc -l < "$TMP/expected.tsv" | tr -d ' ')
[ "$N" -ge 10 ] && ok "cargo metadata lists $N MIT-only crates in the pagetriage-cli tree for all targets" || fail "too few MIT-only crates found ($N)"
expect_eq "the all-targets list holds crunchy 0.2.4 (BUG-T3-S4-21)" 1 "$(grep -cE '^crunchy	0\.2\.4$' "$TMP/expected.tsv")"
expect_eq "the host-only list lacks crunchy: it is what a macOS-only generator would have used" 0 "$(grep -c '^crunchy	' "$TMP/expected-host.tsv")"

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
out=$(check_notice "$NOTICE_TXT" "$TMP/expected.tsv") && ok "every MIT-only crate of the CLI tree (all targets) has its block (name, version, copyright or author, MIT text)" || { fail "MIT-only crate blocks of the CLI tree:"; echo "$out" | sed 's/^/        /'; }

grep -q "Airplane Mode Labs pagetriage" "$NOTICE_TXT" && grep -q "Copyright (c) 2016 Dropbox, Inc." "$NOTICE_TXT" && ok "the CLI NOTICE contains the repository NOTICE (project notice and the BSD attributions)" || fail "the CLI NOTICE lacks the repository NOTICE text"

# Mutation: remove one block; the check must now fail.
python3 -I - "$NOTICE_TXT" "$TMP/mutated" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf8").read()
t2 = re.sub(r"^=== crunchy 0\.2\.4 \(MIT\) ===\n.*?(?=^=== |\Z)", "", t, flags=re.S | re.M)
open(sys.argv[2], "w", encoding="utf8").write(t2)
PY
if check_notice "$TMP/mutated" "$TMP/expected.tsv" >/dev/null 2>&1; then
  if grep -q '^=== crunchy 0.2.4' "$NOTICE_TXT"; then fail "the check passes with the crunchy block removed (the test cannot fail)"; else fail "the file under test has no crunchy 0.2.4 block"; fi
else ok "the check fails when the crunchy 0.2.4 block is removed"; fi

# The generator reproduces the committed file (only when the file under test is the committed one).
if [ -z "${NOTICE_FILE:-}" ]; then
  command -v node >/dev/null || { fail "node not found: scripts/notice-cli.mjs cannot run"; finish; exit $?; }
  if node scripts/notice-cli.mjs "$TMP/generated" >"$TMP/gen.log" 2>&1; then
    cmp -s "$TMP/generated" "$NOTICE_TXT" && ok "scripts/notice-cli.mjs reproduces crates/pagetriage-cli/NOTICE byte for byte" || fail "scripts/notice-cli.mjs output differs from crates/pagetriage-cli/NOTICE (run: node scripts/notice-cli.mjs crates/pagetriage-cli/NOTICE)"
  else fail "scripts/notice-cli.mjs failed: $(tail -2 "$TMP/gen.log")"; fi
  node scripts/notice-cli.mjs --check >/dev/null 2>&1 && ok "scripts/notice-cli.mjs --check exits 0 on the committed file" || fail "scripts/notice-cli.mjs --check exits non-zero on the committed file"
  cp "$NOTICE_TXT" "$TMP/saved"
  # --check must notice a stale file: point it at a copy with a block removed
  node scripts/notice-cli.mjs --check "$TMP/mutated" >/dev/null 2>&1 && fail "--check passes a NOTICE without the crunchy block" || ok "--check fails a NOTICE without the crunchy block"
fi
finish
