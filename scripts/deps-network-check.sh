#!/usr/bin/env bash
# The dependency tree of pagetriage-core may not hold a network-capable crate (Sprint 7, D2-04; the S1 condition on the Dependabot updates): pagetriage
# does no I/O in its core and makes no network request from any host, so a dependency update that drags in reqwest, hyper, ureq, tokio, rustls or native-tls
# (or a crate named after one of them, such as hyper-util or rustls-pemfile) is refused. Both trees are checked: the normal dependencies on every
# target and with every feature (`--target all --all-features`, so the pdf feature and the wasm32 and Windows branches count) and the dev dependencies as well (jsonschema must keep default-features = false, or its HTTP
# resolver would arrive through a test). The wasm_js feature of getrandom, which lopdf needs only on wasm32, must stay in the wasm32 target table.
#
#   scripts/deps-network-check.sh                       check; print the package counts
#   scripts/deps-network-check.sh --record <file>       also write the sorted normal tree ("name vX.Y.Z" per line) to <file>
#   scripts/deps-network-check.sh --compare <file>      also print what was added, removed or changed against a tree recorded earlier
#
# Offline, read-only: it runs `cargo tree --locked` and reads crates/pagetriage-core/Cargo.toml. DEPS_ROOT (default: the repository) names the tree it reads.
set -euo pipefail
ROOT=${DEPS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT"
RECORD=""; COMPARE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --record) RECORD=${2:-}; [ -n "$RECORD" ] || { echo "usage: --record <file>" >&2; exit 2; }; shift 2 ;;
    --compare) COMPARE=${2:-}; [ -n "$COMPARE" ] || { echo "usage: --compare <file>" >&2; exit 2; }; shift 2 ;;
    *) echo "usage: $0 [--record <file>] [--compare <file>]" >&2; exit 2 ;;
  esac
done
if [ -n "$COMPARE" ] && [ ! -f "$COMPARE" ]; then echo "error: $COMPARE does not exist" >&2; exit 1; fi

BANNED='^(reqwest|hyper|ureq|tokio|rustls|native-tls)(-[a-z0-9_-]+)? v'
tree() { # tree <edges>: "name vX.Y.Z" per line, sorted, with the workspace crate's own path suffix removed
  cargo tree --locked -p pagetriage-core --all-features -e "$1" --target all --prefix none | sed -E 's/ \(.*\)$//; s/ \(\*\)$//; s/ \(proc-macro\)$//' | LC_ALL=C sort -u
}
NORMAL=$(tree normal)
DEV=$(tree normal,dev)
fail=0
for which in normal dev; do
  if [ "$which" = normal ]; then T=$NORMAL; else T=$DEV; fi
  hits=$(printf '%s\n' "$T" | grep -E "$BANNED" || true)
  if [ -n "$hits" ]; then echo "error: a network-capable crate is in the $which dependency tree of pagetriage-core:" >&2; printf '%s\n' "$hits" | sed 's/^/  /' >&2; fail=1; fi
done

# wasm_js must sit under the wasm32 target table: walk the manifest table by table
bad=$(awk '/^\[/{tbl=$0} /wasm_js/ && !/^#/ { if (tbl !~ /target_arch = "wasm32"/ || tbl ~ /not\(target_arch = "wasm32"\)/) print tbl ": " $0 }' crates/pagetriage-core/Cargo.toml)
if [ -n "$bad" ]; then echo "error: the wasm_js feature is outside the wasm32 target table:" >&2; printf '%s\n' "$bad" | sed 's/^/  /' >&2; fail=1; fi
[ "$fail" = 0 ] || exit 1

echo "ok: $(printf '%s\n' "$NORMAL" | wc -l | tr -d ' ') packages in the normal tree, $(printf '%s\n' "$DEV" | wc -l | tr -d ' ') with dev dependencies; none is network-capable; wasm_js is limited to wasm32"
if [ -n "$RECORD" ]; then printf '%s\n' "$NORMAL" > "$RECORD"; echo "recorded the normal tree in $RECORD"; fi
if [ -n "$COMPARE" ]; then
  now=$(mktemp "${TMPDIR:-/tmp}/pagetriage-deps.XXXXXX")
  printf '%s\n' "$NORMAL" > "$now"
  echo "== against $COMPARE (the normal tree, name by name)"
  python3 -I - "$COMPARE" "$now" <<'PY'
import sys
def load(p):
    d = {}
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if line:
            n, _, v = line.partition(" ")
            d.setdefault(n, set()).add(v)
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
added = sorted(set(b) - set(a)); removed = sorted(set(a) - set(b))
changed = sorted(n for n in set(a) & set(b) if a[n] != b[n])
for n in added: print("added   ", n, ", ".join(sorted(b[n])))
for n in removed: print("removed ", n, ", ".join(sorted(a[n])))
for n in changed: print("changed ", n, ", ".join(sorted(a[n])), "->", ", ".join(sorted(b[n])))
print(f"{len(added)} added, {len(removed)} removed, {len(changed)} changed, {len(set(a) & set(b)) - len(changed)} unchanged")
PY
  rm -f "$now"
fi
