#!/usr/bin/env bash
# TD-115 (Sprint 7): the README section "## Try it in two minutes" is code that this test extracts and runs, so the section cannot
# go stale. No model download, no test key, no control-weakening instruction.
#
# Fenced blocks inside the section carry one of these info strings (anything else is an error):
#   sh quickstart:setup          run from the repository root (builds the artefacts); skipped with QUICKSTART_REUSE=1
#   sh quickstart:install        run in a fresh empty directory outside the repository; $REPO is the clone, set here
#   <lang> quickstart:file=NAME  written verbatim, as NAME, into that directory
#   sh quickstart:run            run there
#   text quickstart:expect       the exact stdout of the run block before it (LF-normalised lines, trailing whitespace trimmed)
# A plain `sh` block may hold only the git clone line (and a cd into the clone).
#
# Every block runs in a new bash with a scrubbed environment: PATH, HOME (USERPROFILE and SYSTEMROOT when set, for Windows),
# TMPDIR/TEMP/TMP, REPO, npm_config_offline=true, a fresh npm_config_cache, PIP_NO_INDEX=1, PIP_DISABLE_PIP_VERSION_CHECK=1. No
# GITHUB_*, no CI, no token. On Windows (Git Bash) `.venv/bin/` is read as `.venv/Scripts/` and `python3` as `python`.
# Before anything runs, a static pre-check refuses a block that fetches from the network or weakens a control.
#
# Modes (environment):
#   default                 the static pre-check on README.md, and the harness's own tests on synthetic READMEs (seconds)
#   QUICKSTART_RUN=1        also run every block of README.md (release-rehearsal does; the setup block builds, minutes)
#   QUICKSTART_REUSE=1      with QUICKSTART_RUN=1: skip the setup block and require the artefacts it would have built
#   QUICKSTART_ENGINE=1     engine only, on QUICKSTART_README (the harness's own tests call this); exit 0 only if everything passes
#   QUICKSTART_README=file  the README to read (default README.md)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
README=${QUICKSTART_README:-$REPO/README.md}
SECTION='## Try it in two minutes'
BASH_BIN=${BASH:-bash}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;; *) ON_WINDOWS=0 ;; esac

# ---- extraction ------------------------------------------------------------------------------------
# extract <readme> <outdir>: NNN.info and NNN.body per fenced block of the section, and "count". Exit 2 on an unclosed fence,
# 3 when the section is missing.
extract() {
  rm -rf "$2"; mkdir -p "$2"
  awk -v out="$2" '
    BEGIN { in_sec = 0; in_blk = 0; n = 0 }
    {
      line = $0
      if (in_sec && !in_blk && line ~ /^```/) {
        n++; in_blk = 1
        file = sprintf("%s/%03d.body", out, n); infof = sprintf("%s/%03d.info", out, n)
        printf "" > file; close(file)
        print substr(line, 4) > infof; close(infof)
        next
      }
      if (in_blk && line ~ /^```[ \t]*$/) { in_blk = 0; next }
      if (in_blk) { print line >> file; next }
      if (line ~ /^## /) {
        if (line == "## Try it in two minutes") { in_sec = 1; found = 1; next }
        if (in_sec) { exit }
      }
    }
    END { if (in_blk) { print "unclosed fence in the section" > "/dev/stderr"; exit 2 } if (!found) exit 3; print n > (out "/count") }
  ' "$1"
}

# role <info>: setup | install | run | expect | file:NAME | clone | other
role() {
  case "$1" in
    "sh quickstart:setup") echo setup ;;
    "sh quickstart:install") echo install ;;
    "sh quickstart:run") echo run ;;
    "text quickstart:expect") echo expect ;;
    "sh") echo clone ;;
    *" quickstart:file="*) local name=${1#* quickstart:file=}; if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then echo "file:$name"; else echo other; fi ;;
    *) echo other ;;
  esac
}

# ---- static pre-check ------------------------------------------------------------------------------
FORBIDDEN_RE='http://|https://|curl|wget|invoke-webrequest|\|[[:space:]]*(sh|bash)([[:space:]]|$)|(^|[^A-Za-z0-9_])sudo([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])npx([^A-Za-z0-9_]|$)|allowtestkeys|--allow-test-key|--trust-test-key|rfc8032|unsafe-|content-security-policy'
# precheck <dir>: prints one line per violation; exit status 1 when there is any
precheck() {
  local dir=$1 n i info r body bad=0 prev=none seen_setup=0 seen_install=0 seen_run=0
  n=$(cat "$dir/count")
  i=1
  while [ "$i" -le "$n" ]; do
    id=$(printf '%03d' "$i"); info=$(cat "$dir/$id.info"); r=$(role "$info"); body="$dir/$id.body"
    case "$r" in
      other) echo "block $i: info string '$info' is not one of the quick-start roles"; bad=1 ;;
      clone)
        if grep -vE -e '^git clone https://github\.com/AirplaneMode-Labs/pagetriage( .*)?$' -e '^cd pagetriage$' -e '^$' "$body" | gq .; then echo "block $i: a plain sh block may hold only the git clone line"; bad=1; fi ;;
      *)
        if grep -iEn "$FORBIDDEN_RE" "$body" >/dev/null 2>&1; then
          echo "block $i ($info): forbidden text: $(grep -iEn "$FORBIDDEN_RE" "$body" | head -1 | cut -c1-120)"; bad=1
        fi ;;
    esac
    case "$r" in
      setup) seen_setup=1 ;;
      install) seen_install=1 ;;
      run) seen_run=1; if [ "$i" -eq "$n" ]; then echo "block $i: a run block needs an expect block after it"; bad=1; fi ;;
      expect) if [ "$prev" != run ]; then echo "block $i: an expect block must follow a run block"; bad=1; fi ;;
    esac
    if [ "$prev" = run ] && [ "$r" != expect ]; then echo "block $i: the run block before it has no expect block"; bad=1; fi
    prev=$r; i=$((i+1))
  done
  [ "$seen_setup" = 1 ] || { echo "no sh quickstart:setup block"; bad=1; }
  [ "$seen_install" = 1 ] || { echo "no sh quickstart:install block"; bad=1; }
  [ "$seen_run" = 1 ] || { echo "no sh quickstart:run block"; bad=1; }
  return "$bad"
}

# ---- running ---------------------------------------------------------------------------------------
# win_map <file>: on Windows the venv has Scripts/ and the interpreter is python
win_map() {
  if [ "$ON_WINDOWS" = 1 ]; then sed -E -e 's#\.venv/bin/#.venv/Scripts/#g' -e 's/(^|[^A-Za-z0-9_.])python3($|[^A-Za-z0-9_])/\1python\2/g' "$1"; else cat "$1"; fi
}
# norm: LF-normalised, trailing whitespace trimmed per line, trailing blank lines dropped
norm() { tr -d '\r' | sed -e 's/[[:space:]]*$//' | awk '{a[NR]=$0} END{n=NR; while(n>0 && a[n]=="") n--; for(i=1;i<=n;i++) print a[i]}'; }
# run_block <script-file> <cwd> <stdout-file> <stderr-file> <tmp-area>: one new bash, scrubbed environment
run_block() {
  local script=$1 cwd=$2 so=$3 se=$4 area=$5
  local envargs=("PATH=$PATH" "HOME=${HOME:-$area}" "REPO=$REPO" "TMPDIR=$area" "TEMP=$area" "TMP=$area" "npm_config_offline=true" "npm_config_cache=$area/npm-cache" "PIP_NO_INDEX=1" "PIP_DISABLE_PIP_VERSION_CHECK=1")
  [ -n "${USERPROFILE:-}" ] && envargs+=("USERPROFILE=$USERPROFILE")
  [ -n "${SYSTEMROOT:-}" ] && envargs+=("SYSTEMROOT=$SYSTEMROOT")
  [ -n "${SystemRoot:-}" ] && envargs+=("SystemRoot=$SystemRoot")
  [ -n "${CARGO_HOME:-}" ] && [ "${QUICKSTART_PASS_TOOLHOMES:-0}" = 1 ] && envargs+=("CARGO_HOME=$CARGO_HOME")
  [ -n "${RUSTUP_HOME:-}" ] && [ "${QUICKSTART_PASS_TOOLHOMES:-0}" = 1 ] && envargs+=("RUSTUP_HOME=$RUSTUP_HOME")
  ( cd "$cwd" && env -i "${envargs[@]}" "$BASH_BIN" -e -o pipefail "$script" > "$so" 2> "$se" )
}

# engine <readme>: precheck, then (QUICKSTART_RUN=1) run. Prints ok/FAIL lines through ok/fail; no return value.
engine() {
  local readme=$1 work dir n i id info r body prev_run_out="" install_dir="" rc
  work=$(mktemp -d); dir=$work/blocks
  if ! extract "$readme" "$dir" 2> "$work/extract.err"; then fail "the section '$SECTION' is present and its fences are closed ($(cat "$work/extract.err"))"; rm -rf "$work"; return; fi
  n=$(cat "$dir/count")
  if [ "$n" -gt 0 ]; then ok "section '$SECTION': $n fenced blocks"; else fail "section '$SECTION' has fenced blocks"; rm -rf "$work"; return; fi
  if precheck "$dir" > "$work/pre.out"; then ok "static pre-check: no network fetch, no pipe to a shell, no sudo, npx, test key, allow flag or CSP edit in any block"
  else fail "static pre-check"; sed 's/^/      /' "$work/pre.out"; rm -rf "$work"; return; fi
  if [ "${QUICKSTART_RUN:-0}" != 1 ]; then rm -rf "$work"; return; fi

  i=1
  while [ "$i" -le "$n" ]; do
    id=$(printf '%03d' "$i"); info=$(cat "$dir/$id.info"); r=$(role "$info"); body=$dir/$id.body
    area=$work/area-$id; mkdir -p "$area"
    win_map "$body" > "$work/$id.sh"
    case "$r" in
      clone) ;;
      setup)
        if [ "${QUICKSTART_REUSE:-0}" = 1 ]; then ok "block $i (setup): skipped, QUICKSTART_REUSE=1 (the artefacts come from the build steps before)"
        else
          # the setup builds in the repository itself, so it keeps the toolchain homes
          QUICKSTART_PASS_TOOLHOMES=1 run_block "$work/$id.sh" "$REPO" "$area/out" "$area/err" "$area"; rc=$?
          if [ "$rc" = 0 ]; then ok "block $i (setup) exited 0"; else fail "block $i (setup) exited $rc"; tail -20 "$area/err" | sed 's/^/      /'; fi
        fi ;;
      install)
        install_dir=$(mktemp -d "$work/fresh.XXXXXX")
        run_block "$work/$id.sh" "$install_dir" "$area/out" "$area/err" "$area"; rc=$?
        if [ "$rc" = 0 ]; then ok "block $i (install, fresh directory) exited 0"; else fail "block $i (install) exited $rc"; tail -20 "$area/err" | sed 's/^/      /'; fi ;;
      file:*)
        if [ -z "$install_dir" ]; then fail "block $i: a file block before any install block has no directory"; else
          cp "$body" "$install_dir/${r#file:}"; ok "block $i: wrote ${r#file:} ($(wc -c < "$body" | tr -d ' ') bytes) into the fresh directory"
        fi ;;
      run)
        if [ -z "$install_dir" ]; then fail "block $i: a run block before any install block has no directory"; prev_run_out=""; else
          run_block "$work/$id.sh" "$install_dir" "$area/out" "$area/err" "$area"; rc=$?
          if [ "$rc" = 0 ]; then ok "block $i (run) exited 0"; else fail "block $i (run) exited $rc"; tail -20 "$area/err" | sed 's/^/      /'; fi
          prev_run_out=$area/out
        fi ;;
      expect)
        if [ -z "$prev_run_out" ]; then fail "block $i: no run output to compare"; else
          norm < "$body" > "$work/want.txt"; norm < "$prev_run_out" > "$work/got.txt"
          if cmp -s "$work/want.txt" "$work/got.txt"; then ok "block $i (expect) equals the output of the run block before it: $(head -c 60 "$work/want.txt" | head -1)"
          else fail "block $i (expect) differs from the output"; echo "      want: $(head -c 300 "$work/want.txt" | tr '\n' '|')"; echo "      got:  $(head -c 300 "$work/got.txt" | tr '\n' '|')"; fi
        fi ;;
    esac
    i=$((i+1))
  done
  rm -rf "$work"
}

if [ "${QUICKSTART_ENGINE:-0}" = 1 ]; then
  engine "$README"
  finish
  exit $?
fi

# ---- 1. the real README ----------------------------------------------------------------------------
echo "== README.md"
engine "$README"
if [ "${QUICKSTART_RUN:-0}" != 1 ]; then echo "   (blocks were not run: set QUICKSTART_RUN=1; release-rehearsal does)"; fi
if grep -q -F '.venv/Scripts/' "$README"; then ok "README says in one sentence that Windows reads .venv/bin/ as .venv/Scripts/"; else fail "README mentions .venv/Scripts/ (the Windows reading of .venv/bin/)"; fi

# BUG-T1-S7-03: the setup block fetches Rust crates and installs maturin from PyPI, so the section must not say that nothing is downloaded.
# Only the install and run blocks are offline. The statement is checked on the section text (everything between the section heading and the
# first code block) and on the whole README.
INTRO=$(awk '/^## Try it in two minutes$/{on=1; next} on && /^```/{exit} on{print}' "$README" | tr '\n' ' ')
expect_eq "README: the two-minute intro no longer says that nothing is downloaded by the code" 0 "$(printf '%s' "$INTRO" | grep -ciE 'nothing is downloaded|downloads nothing|nothing is fetched by the code')"
expect_eq "README: the two-minute intro says that the setup block downloads Rust crates" 1 "$(printf '%s' "$INTRO" | grep -ciE 'setup block (downloads|fetches)[^.]*crates' | awk '{print ($1>0)?1:0}')"
expect_eq "README: the two-minute intro names maturin 1.16.0, installed once and unhashed" 1 "$(printf '%s' "$INTRO" | grep -ciE 'maturin 1\.16\.0' | awk '{print ($1>0)?1:0}')"
expect_eq "README: the two-minute intro says the install and run blocks run offline with no model, key or account" 1 "$(printf '%s' "$INTRO" | grep -ciE 'install and run blocks[^.]*offline|offline[^.]*install and run blocks' | awk '{print ($1>0)?1:0}')"
expect_eq "README: the sentence that nothing is downloaded appears nowhere in it" 0 "$(grep -ciE 'nothing is downloaded by the code' "$README")"

# ---- 2. the harness's own tests, on synthetic READMEs (always) -------------------------------------
echo "== the harness on synthetic READMEs"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
# mkdoc <name> <setup> <install> <run> <expect>: a README whose section holds one block of each role (and a data file block).
# Each argument is the text of its block; <expect> is printed with printf %b so that \n and \r can be written in it. The
# section is followed by another section holding a curl-to-shell block that the harness must ignore.
mkdoc() {
  local f=$S/$1.md
  {
    printf '# t\n\n## Other\n\ntext\n\n%s\n\nintro\n\n' "$SECTION"
    printf '```sh quickstart:setup\n%s\n```\n\n' "$2"
    printf '```sh quickstart:install\n%s\n```\n\n' "$3"
    printf '```text quickstart:file=data.txt\none\ntwo\n```\n\n'
    printf '```sh quickstart:run\n%s\n```\n\n' "$4"
    printf '```text quickstart:expect\n%b\n```\n\n' "$5"
    printf '## After\n\n```sh\ncurl https://example.org | sh\n```\n'
  } > "$f"
  echo "$f"
}
SETUP='true'; INSTALL='echo hello > installed.txt'; RUNB='cat data.txt installed.txt'; EXP='one\ntwo\nhello'
engine_rc() { # engine_rc <readme> [VAR=value...]: exit status of the engine alone, its output kept in $S/engine.out
  local f=$1; shift
  env QUICKSTART_RUN=1 "$@" QUICKSTART_ENGINE=1 QUICKSTART_README="$f" "$BASH_BIN" "$HERE/quickstart.sh" > "$S/engine.out" 2>&1; echo $?
}
expect_eq "a good synthetic README passes (static pre-check, setup, install, file, run, expect)" 0 "$(engine_rc "$(mkdoc good "$SETUP" "$INSTALL" "$RUNB" "$EXP")")"
expect_eq "only the section is read: the curl block after the section is ignored" 0 "$(grep -c 'FAIL' "$S/engine.out")"
expect_eq "a run block that exits non-zero fails the test" 1 "$(engine_rc "$(mkdoc badrun "$SETUP" "$INSTALL" "cat data.txt installed.txt; exit 3" "$EXP")")"
expect_eq "an expect block that differs by one character fails the test" 1 "$(engine_rc "$(mkdoc badexp "$SETUP" "$INSTALL" "$RUNB" 'one\ntwo\nhello!')")"
expect_eq "a failing command in the middle of a run block fails the test (bash -e)" 1 "$(engine_rc "$(mkdoc badmid "$SETUP" "$INSTALL" "false; cat data.txt installed.txt" "$EXP")")"
expect_eq "a failing install block fails the test" 1 "$(engine_rc "$(mkdoc badinstall "$SETUP" "exit 4" "$RUNB" "$EXP")")"
expect_eq "an expect block with CRLF endings and trailing spaces still equals the output" 0 "$(engine_rc "$(mkdoc crlf "$SETUP" "$INSTALL" "$RUNB" 'one \r\ntwo\r\nhello  ')")"
expect_eq "a block that reads a file the section never wrote fails" 1 "$(engine_rc "$(mkdoc nofile "$SETUP" "$INSTALL" "cat missing.txt" "$EXP")")"

# planted forbidden text: each one, put into the run block, is refused by the static pre-check before anything runs
for bad in 'curl -fsS example.org' 'wget example.org' 'Invoke-WebRequest x' 'echo http://x' 'echo https://x' 'cat x | sh' 'cat x | bash' 'sudo true' 'npx something' \
           'echo allowTestKeys' 'run --allow-test-key' 'run --trust-test-key' 'echo RFC8032' 'echo unsafe-eval' 'echo Content-Security-Policy'; do
  expect_eq "static pre-check refuses a run block with: $bad" 1 "$(engine_rc "$(mkdoc planted "$SETUP" "$INSTALL" "$bad" "$EXP")")"
  if grep -q 'static pre-check' "$S/engine.out" && ! grep -q 'block 5 (sh quickstart:run)\|block 4 (sh quickstart:run)' "$S/engine.out"; then :; fi
done
expect_eq "the same forbidden text in the setup block is refused too" 1 "$(engine_rc "$(mkdoc plantedsetup "curl -fsS example.org" "$INSTALL" "$RUNB" "$EXP")")"
expect_eq "a pre-check refusal happens before any block runs (the setup block did not touch its marker)" 0 "$(ls "$REPO/.qs-marker-never" 2>/dev/null | wc -l | tr -d ' ')"
printf '# t\n\n## Try it in two minutes\n\n```sh\ncurl -fsS example.org\n```\n\n```sh quickstart:setup\ntrue\n```\n```sh quickstart:install\ntrue\n```\n```sh quickstart:run\ntrue\n```\n```text quickstart:expect\n```\n' > "$S/plaincurl.md"
expect_eq "a plain sh block with anything but the clone line is refused" 1 "$(engine_rc "$S/plaincurl.md")"
printf '# t\n\n## Try it in two minutes\n\n```sh\ngit clone https://github.com/AirplaneMode-Labs/pagetriage\ncd pagetriage\n```\n\n```sh quickstart:setup\ntrue\n```\n```sh quickstart:install\ntrue\n```\n```sh quickstart:run\ntrue\n```\n```text quickstart:expect\n```\n' > "$S/clone.md"
expect_eq "the git clone line alone is accepted (the only block that may hold a URL)" 0 "$(engine_rc "$S/clone.md")"
printf '# t\n\n## Try it in two minutes\n\n```sh quickstart:setup\ntrue\n```\n```sh quickstart:install\ntrue\n```\n```sh quickstart:wat\ntrue\n```\n```sh quickstart:run\ntrue\n```\n```text quickstart:expect\n```\n' > "$S/unknown.md"
expect_eq "an unknown quickstart role is refused" 1 "$(engine_rc "$S/unknown.md")"
printf '# t\n\n## Try it in two minutes\n\n```sh quickstart:setup\ntrue\n```\n```sh quickstart:install\ntrue\n```\n```sh quickstart:run\ntrue\n```\n' > "$S/noexpect.md"
expect_eq "a run block without an expect block is refused" 1 "$(engine_rc "$S/noexpect.md")"
printf '# t\n\n## Try it in two minutes\n\n```sh quickstart:setup\ntrue\n```\n```sh quickstart:install\ntrue\n```\n```text quickstart:file=../escape.txt\nx\n```\n```sh quickstart:run\ntrue\n```\n```text quickstart:expect\n```\n' > "$S/escape.md"
expect_eq "a file block whose name has a path separator is refused" 1 "$(engine_rc "$S/escape.md")"
printf '# t\n\n## Other\n\nnothing\n' > "$S/none.md"
expect_eq "a README without the section fails" 1 "$(engine_rc "$S/none.md")"
printf '# t\n\n## Try it in two minutes\n\n```sh quickstart:setup\ntrue\n' > "$S/unclosed.md"
expect_eq "an unclosed fence fails" 1 "$(engine_rc "$S/unclosed.md")"

# the scrubbed environment: a block prints its own environment names
ENVRUN='cat values.txt; if grep -qE "^(GITHUB_|CI$|RUNNER_|ACTIONS_|NODE_AUTH|NPM_TOKEN|GH_TOKEN)" names.txt; then echo LEAK; else echo clean; fi'
ENVINST='env | sed "s/=.*//" | sort > names.txt; env | grep -E "^(npm_config_offline|PIP_NO_INDEX|REPO)=" | sed "s#^REPO=.*#REPO=set#" | sort > values.txt'
expect_eq "blocks see a scrubbed environment: no GITHUB_*, CI, RUNNER_*, token, and the pinned offline settings" 0 \
  "$(engine_rc "$(mkdoc envdoc "$SETUP" "$ENVINST" "$ENVRUN" 'PIP_NO_INDEX=1\nREPO=set\nnpm_config_offline=true\nclean')" GITHUB_SHA=abc GITHUB_REF=refs/heads/main CI=true RUNNER_TEMP=/x GH_TOKEN=secret NPM_TOKEN=secret NODE_AUTH_TOKEN=secret ACTIONS_ID_TOKEN_REQUEST_URL=u)"
# win_map is a pure text rewrite on Windows and nothing elsewhere (tested through the function, whatever the host)
printf '.venv/bin/python3 -I x.py\npython3 -m venv .venv\n' > "$S/w.txt"
expect_eq "on Windows .venv/bin/ is read as .venv/Scripts/ and python3 as python" ".venv/Scripts/python -I x.py|python -m venv .venv|" "$(ON_WINDOWS=1 win_map "$S/w.txt" | tr '\n' '|')"
expect_eq "off Windows the text is untouched" ".venv/bin/python3 -I x.py|python3 -m venv .venv|" "$(ON_WINDOWS=0 win_map "$S/w.txt" | tr '\n' '|')"
finish
