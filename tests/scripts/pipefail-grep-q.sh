#!/usr/bin/env bash
# `producer | grep -q pattern` under `set -o pipefail` is a false negative whenever the producer writes after the first match (CI run 44656239981, job
# "fmt, clippy, test (ubuntu-latest)"): tests/scripts/ci-policy.sh asked
#     job_text "$CI" determinism | grep -qE '^    permissions:'
# job_text is an awk script. The text of the determinism job is 5399 bytes and `permissions:` is on its third line. A pipe takes awk's output in blocks of 4096
# bytes: grep -q reads the first block, finds the match and exits, awk's next block meets a closed pipe, awk is killed by SIGPIPE (status 141) or, where SIGPIPE
# is ignored, gets EPIPE and exits non-zero, and `set -o pipefail` reports the pipeline as failed. The policy said "job determinism sets no permissions" about a
# job that sets them (the log shows no message from awk). The job's text has been over 4096 bytes since 1a6a244 (4309 bytes; 5399 since f278723), so this is a
# race between awk's second write and grep's exit, which an earlier run won and this one lost. BSD awk on a Mac writes the
# lot in one call, so a Mac run never sees it, and no run proves a line safe: the rule is a lint, not a retest.
#
# The fix is `gq` (tests/scripts/lib.sh): grep without -q, with the output discarded, so it reads to the end of its input and the producer never meets a closed
# pipe. Scripts that do not source lib.sh (scripts/, scripts/release/) write `grep ... >/dev/null`. This test (A) reproduces the condition on the real text of
# the determinism job with a producer that deliberately outlives the match, in both SIGPIPE modes, and (B) refuses a new `| grep -q` (or `| grep -m N`, which
# stops early the same way) in the shell scripts and workflow files, including a pipe that ends a line or follows a continuation line.
#
#   tests/scripts/pipefail-grep-q.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1
SCR=$(mktemp -d); trap 'rm -rf "$SCR"' EXIT

echo "== A. a producer that outlives the match (the determinism job of .github/workflows/ci.yml)"
# the text of one job, as ci-policy.sh's job_text writes it
job_text() { awk -v job="$2" '/^jobs:/{inj=1; next} inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/{cur=$1; sub(/:$/,"",cur); on=(cur==job); next} inj && on{print}' "$1"; }
job_text .github/workflows/ci.yml determinism > "$SCR/job.txt"
SIZE=$(wc -c < "$SCR/job.txt" | tr -d ' ')
expect_eq "the determinism job's text is longer than one 4096-byte pipe write (it is $SIZE bytes)" 1 "$([ "$SIZE" -gt 4096 ] && echo 1 || echo 0)"
FIRST=$(grep -n '^    permissions:' "$SCR/job.txt" | head -n 1 | cut -d: -f1)
expect_eq "its permissions: line is in the first block (line $FIRST), so a reader that stops at the first match leaves the writer mid-text" 1 "$([ -n "$FIRST" ] && [ "$FIRST" -lt 20 ] && echo 1 || echo 0)"
# blocks: the file in 4096-byte writes with a pause after each, so the writer is still going when a reader that stops at its first match has gone. dd fails on a
# closed pipe the way awk, sed and unzip do (EPIPE when SIGPIPE is ignored, the signal otherwise).
blocks() { local n=$(( (SIZE + 4095) / 4096 )) i; for ((i = 0; i < n; i++)); do dd if="$SCR/job.txt" bs=4096 skip="$i" count=1 2>/dev/null || return 1; sleep 0.05; done; }
# in_mode <default|ignored> <function and arguments...>: runs a pipeline under pipefail in a subshell, with SIGPIPE at its default or ignored as in Actions
in_mode() { local mode=$1; shift; ( set -o pipefail; [ "$mode" = ignored ] && trap '' PIPE; "$@" ); }
via_gq()        { blocks | gq -E '^    permissions:'; }
via_gq_miss()   { blocks | gq -E '^    a line the job does not hold'; }
via_gq_x()      { printf 'a\nab\n' | gq -x a; }
via_gq_x_miss() { printf 'ab\n' | gq -x a; }
via_gq_F()      { printf 'x 2.3.4 y\n' | gq -F '2.3.4'; }
for mode in default ignored; do
  in_mode "$mode" via_gq 2>/dev/null;      expect_eq "gq finds permissions: in the block-wise job text, SIGPIPE $mode (the pipeline status is 0)" 0 "$?"
  in_mode "$mode" via_gq_miss 2>/dev/null; expect_eq "gq still reports a miss, SIGPIPE $mode (status 1)" 1 "$?"
done
in_mode default via_gq_x 2>/dev/null;      expect_eq "gq passes -x through (an exact line matches)" 0 "$?"
in_mode default via_gq_x_miss 2>/dev/null; expect_eq "gq passes -x through (a longer line does not match)" 1 "$?"
in_mode default via_gq_F 2>/dev/null;      expect_eq "gq passes -F through" 0 "$?"
OUT=$(blocks | gq -E '^    permissions:' 2>&1); expect_eq "gq prints nothing" "" "$OUT"
# The hazard itself, for the record. Not an assertion: a shell where the writer happens to win would make it a false red. It is what the lint in B exists for.
unsafe() { blocks | grep -qE '^    permissions:'; }
for mode in default ignored; do
  in_mode "$mode" unsafe 2>/dev/null; rc=$?
  echo "note - the same pipeline with grep -q, SIGPIPE $mode: status $rc ($([ "$rc" -eq 0 ] && echo 'the writer won here; not a proof of safety' || echo 'the false negative of CI run 44656239981'))"
done

echo "== B. no pipeline into grep -q (or grep -m N) in a script that may run under pipefail"
# logical <file>: file:line:text of every logical line outside a comment line. A line that ends in a pipe or a backslash is joined to the next one (the pipe may end
# one line and grep -q start the next); a YAML block indicator (`run: |`) is not a pipe.
logical() {
  awk -v f="$1" '
    /^[[:space:]]*#/ { next }
    { line = $0; sub(/[[:space:]]+$/, "", line)
      if (held == "") { start = FNR; held = line } else { sub(/^[[:space:]]+/, "", line); held = held " " line }
      if (line ~ /:[[:space:]]*[|>][-+]?$/) { print f ":" start ":" held; held = ""; next }
      if (line ~ /(\||\\)$/) { sub(/\\$/, "", held); next }
      print f ":" start ":" held; held = "" }
    END { if (held != "") print f ":" start ":" held }' "$1"
}
# The pattern: a single pipe (not the || of an or-list), then grep/egrep/fgrep (optionally after VAR=value words, a path or `command`), then a flag cluster that
# holds q or m (-q, -qF, -Eq, -m1) or --quiet, --silent, --max-count, anywhere before the next pipe or list separator.
HAZARD='(^|[^|])\|&?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(command[[:space:]]+|/[a-z/]*/)?[ef]?grep[[:space:]]+([^|;&)(]*[[:space:]])?(-[A-Za-z]*[qm][A-Za-z0-9]*([[:space:]]|$|=)|--quiet|--silent|--max-count)'
# hazards <files...>: file:line:text of every hit
hazards() { local f; for f in "$@"; do logical "$f" | grep -E "$HAZARD"; done; true; }
printf '%s\n' 'tail -n 5 log | grep -qF done' > "$SCR/bad1.sh"
printf '%s\n' 'printf x | grep -m1 x' > "$SCR/bad2.sh"
printf '%s\n' 'printf x | grep -E -q x' > "$SCR/bad3.sh"
printf '%s\n' 'cmd |' '  grep -q x' > "$SCR/bad4.sh"
printf '%s\n' 'cmd a \' '  | grep -qx x' > "$SCR/bad5.sh"
printf '%s\n' 'x=$(cmd | LC_ALL=C grep -Fq x)' > "$SCR/bad6.sh"
printf '%s\n' 'cmd | grep -E x --max-count=1' > "$SCR/bad7.sh"
printf '%s\n' 'cmd 2>&1 | /usr/bin/grep -iq x' > "$SCR/bad8.sh"
printf '%s\n' 'tail -n 5 log | gq -F done' > "$SCR/ok1.sh"
printf '%s\n' 'grep -qF done log' > "$SCR/ok2.sh"
printf '%s\n' '  # a comment: sed -n p f | grep -q x' > "$SCR/ok3.sh"
printf '%s\n' 'a=$(sysctl -n x 2>/dev/null || grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)' > "$SCR/ok4.sh"
printf '%s\n' 'cmd | grep -c x' 'cmd | grep -vE -e "^a" -e "^$"' 'cmd | grep -iEn "a -b" | head -n 1' > "$SCR/ok5.sh"
printf '%s\n' '        run: |' '          grep -q x file' > "$SCR/ok6.sh"
printf '%s\n' 'cmd | grep x >/dev/null' 'cmd | grep -e "-q" -e "-m"' > "$SCR/ok7.sh"
BAD=0; for n in 1 2 3 4 5 6 7 8; do [ -n "$(hazards "$SCR/bad$n.sh")" ] && BAD=$((BAD+1)) || echo "  the lint missed bad$n.sh: $(cat "$SCR/bad$n.sh" | tr '\n' ' ')"; done
expect_eq "the lint sees all 8 spellings of a pipeline into grep -q or grep -m (flag cluster, later flag, long form, continuation, env prefix, path)" 8 "$BAD"
OKS=0; for n in 1 2 3 4 5 6 7; do [ -z "$(hazards "$SCR/ok$n.sh")" ] && OKS=$((OKS+1)) || echo "  the lint flagged ok$n.sh: $(hazards "$SCR/ok$n.sh")"; done
expect_eq "the lint passes all 7 safe lines (gq, a file operand, a comment, a || list, grep -c, a YAML block, a pattern that holds -q)" 7 "$OKS"

FILES=(tests/scripts/*.sh scripts/*.sh scripts/lib/*.sh scripts/release/*.sh bench/*.sh .github/workflows/*.yml)
# this file holds the hazard on purpose (the 'unsafe' function above and its self-test lines)
LIST=()
for f in "${FILES[@]}"; do case "$f" in tests/scripts/pipefail-grep-q.sh) ;; *) LIST+=("$f") ;; esac; done
HITS=$(hazards "${LIST[@]}")
NHITS=0; [ -n "$HITS" ] && NHITS=$(printf '%s\n' "$HITS" | grep -c '')
expect_eq "no shell script or workflow pipes into grep -q or grep -m N (use gq from tests/scripts/lib.sh, or grep >/dev/null)" 0 "$NHITS"
if [ -n "$HITS" ]; then printf '%s\n' "$HITS" | cut -c1-200 | sed 's/^/    /' | head -n 60; fi
COVERED=0
for want in tests/scripts/ci-policy.sh tests/scripts/lib.sh scripts/package-npm.sh scripts/lib/version.sh scripts/release/rehearse.sh scripts/release/publish-dry-run.sh bench/record_all.sh .github/workflows/ci.yml .github/workflows/publish.yml; do
  for f in "${LIST[@]}"; do [ "$f" = "$want" ] && { COVERED=$((COVERED+1)); break; }; done
done
expect_eq "the lint covers the test scripts, the build scripts, the release scripts, the bench script and the workflows" 9 "$COVERED"
expect_eq "tests/scripts/run-all.sh runs this lint (so CI does)" 1 "$([ "$(tr ' ' '\n' < tests/scripts/run-all.sh | grep -cxF 'pipefail-grep-q.sh')" = 1 ] && echo 1 || echo 0)"
# Every shell script and workflow git knows about is in the lint's file list (a new directory of scripts would otherwise escape it).
# "Knows about" is tracked files AND untracked files that are not ignored (`git ls-files --cached --others --exclude-standard`): the files the next commit holds
# once it is made with `git add -A`. A tracked-only list passes on a working tree where a new script is still untracked and goes red on CI the moment the script
# is committed (CI run 44678293921: bench/record_all.sh, added by 3b6e443, was in none of the globs above, and this check could not see it before the commit).
# Files that are ignored (a .venv, bench/data, target/) never count; a tracked file that is deleted in the working tree is skipped.
# uncovered <git working tree>: the shell scripts and workflows in it that are not in $LIST, space-separated
uncovered() {
  local d=$1 f g found missing=""
  while IFS= read -r f; do
    [ -e "$d/$f" ] || continue
    [ "$f" = tests/scripts/pipefail-grep-q.sh ] && continue
    case "$f" in .github/ISSUE_TEMPLATE/*|.github/dependabot.yml) continue ;; esac
    found=0; for g in "${LIST[@]}"; do [ "$g" = "$f" ] && { found=1; break; }; done
    [ "$found" = 1 ] || missing="$missing $f"
  done < <(git -C "$d" ls-files --cached --others --exclude-standard -- '*.sh' '.github/workflows/*.yml' '.github/workflows/*.yaml' | sort -u)
  printf '%s' "$missing"
}
if git rev-parse --git-dir >/dev/null 2>&1; then
  expect_eq "every tracked or untracked-but-not-ignored .sh file and workflow is covered by the lint" "" "$(uncovered "$REPO")"
  # the check itself, on a scratch repository: a script git has not seen yet must be reported (the CI run above); an ignored one, and one deleted after
  # `git add`, must not be. Nothing here touches the real repository.
  UNT=$(mktemp -d); git -C "$UNT" init -q 2>/dev/null
  mkdir -p "$UNT/newdir" "$UNT/bench/data"
  printf '#!/usr/bin/env bash\n' > "$UNT/newdir/untracked.sh"
  printf '#!/usr/bin/env bash\n' > "$UNT/bench/data/ignored.sh"; printf 'bench/data/\n' > "$UNT/.gitignore"
  printf '#!/usr/bin/env bash\n' > "$UNT/gone.sh"; git -C "$UNT" add gone.sh 2>/dev/null; rm -f "$UNT/gone.sh"
  expect_eq "the coverage check reports a new script that is untracked, and skips an ignored one and a deleted one" " newdir/untracked.sh" "$(uncovered "$UNT")"
  rm -rf "$UNT"
else
  echo "note - not a git checkout (no .git): the check that every .sh file and workflow is covered by the lint is skipped; it needs git's file list"
fi
finish
