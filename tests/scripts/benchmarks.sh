#!/usr/bin/env bash
# The benchmark rule (owner decision, 20 Nov 2026): every figure quoted anywhere has its raw file committed under docs/benchmarks/, with its
# date, commit, machine and method, an index says what each file is and how to reproduce it, and the README and the demo link the folder.
# tests/scripts/benchmarks-check.mjs makes the checks (see its header); this script runs it on the real inputs and then on scratch copies of
# them with one thing broken at a time, each of which must fail with the message that names it. A rule that no planted break can turn
# red is not a rule.
#
#   tests/scripts/benchmarks.sh
#
# Inputs: README.md, bench/README.md, site/index.html, docs/ (the whole folder, benchmarks included). Nothing else: no network, no sibling repository, no build
# output (target/, dist/), no downloaded data (bench/data/, DIBCO), no Python environment (.venv), no interpreter but Node.
#
# What the checker reads is a COPY made from git's file list (tracked files plus untracked files that are not ignored: what the next commit holds). It is not
# the working tree. So a raw file that is gitignored, a stray file in docs/, or anything else that exists only on this machine cannot satisfy a check that a clean
# checkout would fail: the test gives the same answer on a fresh clone as in a dirty tree. Outside a git checkout (a source tarball) it copies the inputs as they are.
#
# Not checked here, because each needs a build or data and is run by hand (bench/record_all.sh): that the sizes in docs/benchmarks/eval-sizes.json equal the sizes of
# artefacts built today, that the DIBCO figures reproduce from the downloaded pages, and that a timing re-measures. This test checks that a quoted figure is a
# committed record, not that the record is true; the last lines it prints say so.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { fail "node not found: benchmarks.sh cannot run (Node 22 is required)"; finish; exit 1; }
CHECK=$REPO/tests/scripts/benchmarks-check.mjs
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
INPUTS=(README.md bench/README.md site/index.html docs)
GIT=0; git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && GIT=1

# Windows (Git Bash): node.exe cannot open /tmp/... or /d/a/..., so every path handed to node is spelled C:/... (cygpath -m); elsewhere it is unchanged.
npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
# run_check <root>: the checker on a tree
run_check() { ROOT=$(npath "$1") node "$(npath "$CHECK")"; }
# plant <command> <file or directory under the copy> <args...>: a planted edit (benchmarks-plant.mjs). MSYS must not rewrite its arguments (a quoted JSON
# fragment, a path inside text), so the file is spelled by npath and the conversion is switched off for the call.
plant() { local c=$1 f=$2; shift 2; MSYS2_ARG_CONV_EXCL='*' node "$(npath "$REPO/tests/scripts/benchmarks-plant.mjs")" "$c" "$(npath "$f")" "$@"; }

# snapshot <dest>: the checker's inputs, as git lists them (or as they are, outside git)
NFILES=0
snapshot() {
  local dest=$1 f
  rm -rf "$dest"; mkdir -p "$dest"
  if [ "$GIT" = 1 ]; then
    while IFS= read -r -d '' f; do
      [ -f "$REPO/$f" ] || continue   # tracked, deleted in the working tree
      mkdir -p "$dest/$(dirname "$f")"; cp "$REPO/$f" "$dest/$f"; NFILES=$((NFILES+1))
    done < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard -- "${INPUTS[@]}")
  else
    for f in "${INPUTS[@]}"; do mkdir -p "$dest/$(dirname "$f")"; cp -R "$REPO/$f" "$dest/$f"; done
  fi
}

echo "== the inputs"
snapshot "$S/base"
if [ "$GIT" = 1 ]; then
  IGN=$(git -C "$REPO" ls-files --others --ignored --exclude-standard -- "${INPUTS[@]}" | wc -l | tr -d ' ')
  UNT=$(git -C "$REPO" ls-files --others --exclude-standard -- "${INPUTS[@]}" | wc -l | tr -d ' ')
  CHG=$(git -C "$REPO" status --porcelain --untracked-files=no -- "${INPUTS[@]}" | wc -l | tr -d ' ')
  echo "note - the checker reads a copy of $NFILES files made from git's file list; $IGN ignored file(s) under those paths are left out (a clean checkout does not have them)"
  [ "$UNT" -eq 0 ] || echo "note - $UNT file(s) it reads are not tracked yet: CI sees them only after the commit adds them"
  [ "$CHG" -eq 0 ] || echo "note - $CHG tracked path(s) it reads differ from HEAD: CI reads the commit, not this working tree"
else
  echo "note - not a git checkout (no .git): the checker reads a plain copy of README.md, bench/README.md, site/index.html and docs/; the line-ending attribute check is skipped"
fi
HAVE=0; for f in README.md bench/README.md site/index.html docs/benchmarks/README.md; do [ -f "$S/base/$f" ] && HAVE=$((HAVE+1)); done
expect_eq "the copy holds the inputs (README.md, bench/README.md, site/index.html, docs/benchmarks/README.md)" 4 "$HAVE"
EXTRA=0; for d in target dist bench/data .venv node_modules; do [ -e "$S/base/$d" ] && EXTRA=$((EXTRA+1)); done
expect_eq "the copy holds no build output, downloaded data or environment (target, dist, bench/data, .venv, node_modules)" 0 "$EXTRA"

# the checks on the real inputs: every line of the checker's output is one assertion
echo "== the real inputs"
run_check "$S/base" > "$S/real.txt" 2> "$S/real.err" || { cat "$S/real.err"; fail "the benchmark checker crashed"; }
while IFS= read -r line; do
  case "$line" in
    "ok   - "*) ok "${line#ok   - }" ;;
    "FAIL - "*) fail "${line#FAIL - }" ;;
  esac
done < "$S/real.txt"
NREAL=$(grep -c '^ok  ' "$S/real.txt")
expect_eq "the checker made at least 300 assertions on the real inputs" yes "$([ "$(grep -c '^\(ok  \|FAIL\)' "$S/real.txt")" -ge 300 ] && echo yes || echo no)"

# line endings: .gitattributes must check every text input out with LF on every platform (a CRLF checkout changes the bytes the claims quote). `git ls-files --eol`
# prints "i/<index eol> w/<working-tree eol> attr/<attributes> <path>"; the index must be LF and the attributes must say eol=lf.
if [ "$GIT" = 1 ]; then
  git -C "$REPO" ls-files --eol -- "${INPUTS[@]}" | grep -E '\.(md|json|csv|html)$' > "$S/eol.txt"
  NTEXT=$(grep -c '' "$S/eol.txt")
  BADEOL=$(grep -vcE '^i/(lf|none) .*attr/.*eol=lf' "$S/eol.txt")
  expect_eq "every .md, .json, .csv and .html input is LF in the index and carries eol=lf from .gitattributes ($NTEXT files, so a Windows checkout reads LF)" 0 "$BADEOL"
fi

# a scratch copy of what the checker reads
fresh() { rm -rf "$S/t"; cp -R "$S/base" "$S/t"; }
# edit <file under the copy> <old text> <new text>: replaces every occurrence, and fails the test itself when the old text is not there
edit() { plant replace "$S/t/$1" "$2" "$3"; }
# broken <name> <message fragment the checker must fail with>: runs the checker on the copy; it must print a FAIL line holding the fragment
broken() {
  local name=$1 want=$2
  run_check "$S/t" > "$S/out.txt" 2> "$S/err.txt" || { fail "planted: $name (the checker crashed: $(head -c 200 "$S/err.txt"))"; return; }
  if grep '^FAIL' "$S/out.txt" | gq -F -- "$want"; then ok "planted: $name is refused ($want)"; else fail "planted: $name was not refused with '$want'; the failures were: $(grep '^FAIL' "$S/out.txt" | head -3 | cut -c1-200 | tr '\n' '|')"; fi
}
clean_check() { # the copy before any edit must pass: otherwise the planted failures prove nothing
  fresh; run_check "$S/t" > "$S/out.txt" 2>&1; expect_eq "the unedited scratch copy has no failure" 0 "$(grep -c '^FAIL' "$S/out.txt")"
}

echo "== line endings"
# the same inputs with CRLF line endings (a checkout with core.autocrlf=true and no eol rule): no failure, and not one passing assertion fewer
fresh; plant crlf "$S/t"; run_check "$S/t" > "$S/crlf.txt" 2>&1
expect_eq "a copy with CRLF line endings has no failure" 0 "$(grep -c '^FAIL' "$S/crlf.txt")"
expect_eq "a copy with CRLF line endings makes the same number of passing assertions as the LF copy ($NREAL)" "$NREAL" "$(grep -c '^ok  ' "$S/crlf.txt")"

echo "== planted breaks"
clean_check

fresh; edit README.md "67.4 ms" "67.5 ms" && broken "a README speed figure changed (67.4 to 67.5 ms)" "still says"
fresh; edit docs/benchmarks/speed.csv ",67.4," ",67.5," && broken "the speed CSV row changed (67.4 to 67.5)" "equals the row"
fresh; plant drop-lines "$S/t/docs/benchmarks/speed.csv" has "A4 100 dpi"
broken "the A4 100 dpi row deleted from the speed CSV" "has exactly one row"
fresh; edit README.md "| not measured on 8 GB | Apple M5 Pro (the file names the model, not the RAM), commit eb28e490030b-dirty" "| not measured on 8 GB | 99.9 ms; Apple M5 Pro (the file names the model, not the RAM), commit eb28e490030b-dirty" && broken "a new figure (99.9 ms) in a README Benchmarks cell with no claim" "every number in the trust cell has a claim"
fresh; edit README.md "## Limitations" "A new page takes 12.5 ms to analyse.

## Limitations" && broken "a new timing sentence in the README with no claim" "timing, throughput or byte-count line"
fresh; edit README.md "the other half (159 pages) scored 159 of 159" "the other half (159 pages) scored 158 of 159" && broken "the held-out accuracy edited (159 to 158 of 159)" "still says"
fresh; plant drop-lines "$S/t/docs/benchmarks/README.md" starts '| `large-doc.csv`'
broken "a file left out of the index" "large-doc.csv has a row in the index"
fresh; edit docs/benchmarks/README.md "Nothing here was measured on an 8 GB laptop unless a file says so" "Everything here was measured on an 8 GB laptop" && broken "the standing 8 GB line removed from the index" "standing line"
fresh; plant drop-first-column "$S/t/docs/benchmarks/streams-native.csv"
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
fresh; plant drop-lines "$S/t/docs/detectors/stamp.md" starts '**Raw results:**'
broken "a detector page whose results section has no Raw results line" "docs/detectors/stamp.md: a results section needs"
fresh; edit docs/detectors/stamp.md "docs/benchmarks/eval-stamp-synth.json" "docs/benchmarks/eval-stamp-nothing.json" && broken "a Raw results line naming a file that is not committed" "not committed"
fresh; edit docs/wasm-api.md "(about 88 ms for 300 pages here" "(about 91 ms for 300 pages here" && broken "docs/wasm-api.md quotes a timing that is not in the CSV" "still says"
fresh; rm "$S/t/docs/benchmarks/eval-skew-white.json"; broken "a raw file deleted while the README and the demo still quote it" "is not a committed file"

echo "== what this test does not check"
echo "note - skipped, needs a build: the sizes in docs/benchmarks/eval-sizes.json against artefacts built today (bench/record_all.sh sizes). CI builds those artefacts in other jobs; this test does not compare them"
echo "note - skipped, needs data: the DIBCO figures against the downloaded pages (python -I bench/fetch.py, then bench/record_all.sh dibco); the pages cannot be redistributed and are not in git"
echo "note - skipped, needs the machine: no timing is re-measured; a CSV row or JSON record is the measurement with its date, commit and machine, and the checker proves each quote equals it"
finish
