#!/usr/bin/env bash
# The benchmark rule (owner decision, 20 Nov 2026): every figure quoted anywhere has its raw file committed under docs/benchmarks/, with its
# date, commit, machine and method, an index says what each file is and how to reproduce it, and the README and the demo link the folder.
# tests/scripts/benchmarks-check.mjs makes the checks (see its header); this script runs it on the real tree and then on scratch copies of
# the tree with one thing broken at a time, each of which must fail with the message that names it. A rule that no planted break can turn
# red is not a rule.
#
#   tests/scripts/benchmarks.sh
#
# Inputs: README.md, bench/README.md, site/index.html, docs/ (the whole folder, benchmarks included). No network, no sibling repository.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { fail "node not found: benchmarks.sh cannot run (Node 22 is required)"; finish; exit 1; }
command -v python3 >/dev/null || command -v python >/dev/null || { fail "python not found"; finish; exit 1; }
PY=python3; command -v python3 >/dev/null || PY=python
CHECK=$REPO/tests/scripts/benchmarks-check.mjs
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT

# the checks on the real tree: every line of the checker's output is one assertion
echo "== the real tree"
ROOT=$REPO node "$CHECK" > "$S/real.txt" 2> "$S/real.err" || { cat "$S/real.err"; fail "the benchmark checker crashed"; }
while IFS= read -r line; do
  case "$line" in
    "ok   - "*) ok "${line#ok   - }" ;;
    "FAIL - "*) fail "${line#FAIL - }" ;;
  esac
done < "$S/real.txt"
expect_eq "the checker made at least 300 assertions on the real tree" yes "$([ "$(grep -c '^\(ok  \|FAIL\)' "$S/real.txt")" -ge 300 ] && echo yes || echo no)"

# a scratch copy of what the checker reads
fresh() {
  rm -rf "$S/t"; mkdir -p "$S/t/bench" "$S/t/site"
  cp "$REPO/README.md" "$S/t/README.md"; cp "$REPO/bench/README.md" "$S/t/bench/README.md"; cp "$REPO/site/index.html" "$S/t/site/index.html"
  cp -R "$REPO/docs" "$S/t/docs"
}
# edit <file under the copy> <old text> <new text>: replaces every occurrence, and fails the test itself when the old text is not there
edit() {
  "$PY" - "$S/t/$1" "$2" "$3" <<'PYEND' || return 1
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit("the planted edit's old text is not in " + path + ": " + old[:60])
open(path, "w", encoding="utf-8", newline="").write(text.replace(old, new))
PYEND
}
# broken <name> <message fragment the checker must fail with>: runs the checker on the copy; it must print a FAIL line holding the fragment
broken() {
  local name=$1 want=$2
  ROOT=$S/t node "$CHECK" > "$S/out.txt" 2> "$S/err.txt" || { fail "planted: $name (the checker crashed: $(head -c 200 "$S/err.txt"))"; return; }
  if grep '^FAIL' "$S/out.txt" | gq -F -- "$want"; then ok "planted: $name is refused ($want)"; else fail "planted: $name was not refused with '$want'; the failures were: $(grep '^FAIL' "$S/out.txt" | head -3 | cut -c1-200 | tr '\n' '|')"; fi
}
clean_check() { # the copy before any edit must pass: otherwise the planted failures prove nothing
  fresh; ROOT=$S/t node "$CHECK" > "$S/out.txt" 2>&1; expect_eq "the unedited scratch copy has no failure" 0 "$(grep -c '^FAIL' "$S/out.txt")"
}

echo "== planted breaks"
clean_check

fresh; edit README.md "67.4 ms" "67.5 ms" && broken "a README speed figure changed (67.4 to 67.5 ms)" "still says"
fresh; edit docs/benchmarks/speed.csv ",67.4," ",67.5," && broken "the speed CSV row changed (67.4 to 67.5)" "equals the row"
fresh; "$PY" - "$S/t/docs/benchmarks/speed.csv" <<'PYEND'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
open(p, "w", encoding="utf-8", newline="").write("\n".join(l for l in lines if "A4 100 dpi" not in l))
PYEND
broken "the A4 100 dpi row deleted from the speed CSV" "has exactly one row"
fresh; edit README.md "| not measured on 8 GB | Apple M5 Pro (the file names the model, not the RAM), commit eb28e490030b-dirty" "| not measured on 8 GB | 99.9 ms; Apple M5 Pro (the file names the model, not the RAM), commit eb28e490030b-dirty" && broken "a new figure (99.9 ms) in a README Benchmarks cell with no claim" "every number in the trust cell has a claim"
fresh; edit README.md "## Limitations" "A new page takes 12.5 ms to analyse.

## Limitations" && broken "a new timing sentence in the README with no claim" "timing, throughput or byte-count line"
fresh; edit README.md "the other half (159 pages) scored 159 of 159" "the other half (159 pages) scored 158 of 159" && broken "the held-out accuracy edited (159 to 158 of 159)" "still says"
fresh; "$PY" - "$S/t/docs/benchmarks/README.md" <<'PYEND'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
open(p, "w", encoding="utf-8", newline="").write("\n".join(l for l in lines if not l.startswith("| `large-doc.csv`")))
PYEND
broken "a file left out of the index" "large-doc.csv has a row in the index"
fresh; edit docs/benchmarks/README.md "Nothing here was measured on an 8 GB laptop unless a file says so" "Everything here was measured on an 8 GB laptop" && broken "the standing 8 GB line removed from the index" "standing line"
fresh; "$PY" - "$S/t/docs/benchmarks/streams-native.csv" <<'PYEND'
import sys
p = sys.argv[1]
rows = open(p, encoding="utf-8").read().split("\n")
rows[0] = rows[0].replace("date,", "", 1)
out = [rows[0]] + [r.split(",", 1)[1] if r else r for r in rows[1:]]
open(p, "w", encoding="utf-8", newline="").write("\n".join(out))
PYEND
broken "the date column removed from a CSV" "streams-native.csv has the columns"
fresh; edit docs/benchmarks/eval-quality-time.json '"exit_code": 0' '"exit_code": 1' && broken "a record whose command failed" "the command exited 0"
fresh; edit docs/benchmarks/eval-quality-time.json '"commit": "' '"commitx": "' && broken "a record with no commit" "has the fields of a bench record"
fresh; edit docs/benchmarks/eval-quality-time.json '"stdout": [' '"stdout": ["/Users/someone/pagetriage/bench/x.py",' && broken "a record holding a home path" "holds no home or builder path"
fresh; edit docs/benchmarks/eval-quality-time.json '"eight_gb_laptop": "not measured on 8 GB"' '"eight_gb_laptop": "measured on 8 GB: a laptop"' && broken "a record claiming an 8 GB laptop on a 48 GiB machine" "so its machine must be an 8 GB laptop"
fresh; edit docs/benchmarks/eval-quality-time.json '48 GiB RAM' '8 GiB RAM' && broken "a record on an 8 GiB machine that does not say it was measured there" "is an 8 GB laptop but the file does not say"
fresh; edit README.md "megapixel; raw data not kept), so run it" "megapixel), so run it" && broken "the words 'raw data not kept' removed next to a figure that has no raw file (its claim quotes them)" "still says"
fresh; edit site/index.html "quality pass about 68 ms" "quality pass about 70 ms" && broken "the demo quotes a figure that is not in the raw file" "still says"
fresh; edit site/index.html 'tree/main/docs/benchmarks"' 'tree/main/docs"' && broken "the demo does not link docs/benchmarks/" "demo links the docs/benchmarks/ folder"
fresh; edit README.md "docs/benchmarks/" "docs/bench/" && broken "the README stops linking docs/benchmarks/" "links docs/benchmarks/"
fresh; "$PY" - "$S/t/docs/detectors/stamp.md" <<'PYEND'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
open(p, "w", encoding="utf-8", newline="").write("\n".join(l for l in lines if not l.startswith("**Raw results:**")))
PYEND
broken "a detector page whose results section has no Raw results line" "docs/detectors/stamp.md: a results section needs"
fresh; edit docs/detectors/stamp.md "docs/benchmarks/eval-stamp-synth.json" "docs/benchmarks/eval-stamp-nothing.json" && broken "a Raw results line naming a file that is not committed" "not committed"
fresh; edit docs/wasm-api.md "(about 88 ms for 300 pages here" "(about 91 ms for 300 pages here" && broken "docs/wasm-api.md quotes a timing that is not in the CSV" "still says"
fresh; rm "$S/t/docs/benchmarks/eval-skew-white.json"; broken "a raw file deleted while the README and the demo still quote it" "is not a committed file"
finish
