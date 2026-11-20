#!/usr/bin/env bash
# The release rehearsal (TD-103, TD-106, Sprint 7): build every artefact kind exactly as a release would, install each BUILT
# artefact into an empty project, make one real call on a synthetic golden page, then produce the release manifest and
# SHA256SUMS, sign them with the published RFC 8032 TEST key, verify them with the repository's own verifier and prove that
# the same artefacts are refused without the explicit test-key flag. It signs nothing real, publishes nothing and reads no
# secret. The CI job `release-rehearsal (<os>)` runs `all` on Linux, macOS and Windows; this script runs the same steps on a Mac.
#
#   bash scripts/release/rehearse.sh [tools|build|install|sign|gate|all]        (default: all)
#
#   tools    a venv with maturin, uv and ziglang installed from tools/ci/requirements.txt by hash (CI does this in its own step)
#   build    npm tarball (PDF build), wheel, CLI binary, and on Linux the sdist and a wheel built from the sdist alone;
#            `cargo package --workspace --locked` twice (the .crate files must be byte-identical, S1-126); then the flat
#            directory dist-release/ holds the artefacts and nothing else
#   install  npm tarball, wheel, sdist-built wheel and the CLI built from the packaged crates, each installed into an empty
#            project or fresh venv and called once; the path of what ran is shown and checked
#   sign     release manifest and SHA256SUMS, TEST-key signature, verification, and the exact refusal proofs
#   gate     dist-release/ holds only the manifest entries, release-manifest.json and SHA256SUMS; no key material; builder paths
#
# Output: dist-release/ (artefacts, release-manifest.json, SHA256SUMS) and the sibling dist-release-report/ (logs and the
# refusal table), both under REHEARSE_OUT_ROOT (default: the repository root). Both are git-ignored and are what CI uploads.
# Environment: REHEARSE_SDIST=1 builds the sdist (and a wheel from it) on any OS, not only on Linux; SOURCE_DATE_EPOCH (default: the commit time, else now); RELEASE_TOOL (default scripts/release/release-tool.mjs);
# PAGETRIAGE_TOOLS_VENV (default tools-venv); REHEARSE_ALLOW_DIRTY=1 passes --allow-dirty to cargo package (local runs only).
# The script never reads GITHUB_SHA or GITHUB_REF.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$(pwd)
# shellcheck source=../lib/version.sh
. scripts/lib/version.sh
VERSION=$(workspace_version Cargo.toml)
PYVER=$(py_version "$VERSION")
OUT_ROOT=${REHEARSE_OUT_ROOT:-$REPO}
DIST=$OUT_ROOT/dist-release
REPORT=$OUT_ROOT/dist-release-report
TOOL=${RELEASE_TOOL:-scripts/release/release-tool.mjs}
case "$TOOL" in /*|[A-Za-z]:*) TOOL_PATH=$TOOL ;; *) TOOL_PATH=$REPO/$TOOL ;; esac
TOOLS_VENV=${PAGETRIAGE_TOOLS_VENV:-tools-venv}
case "$TOOLS_VENV" in /*|[A-Za-z]:*) ;; *) TOOLS_VENV=$REPO/$TOOLS_VENV ;; esac
MANIFEST_ID=pagetriage-rehearsal
LICENCE='MIT OR Apache-2.0'
PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1; OSNAME=windows ;; Darwin) WIN=0; OSNAME=macos ;; *) WIN=0; OSNAME=linux ;; esac

log() { printf '== %s\n' "$*"; }
die() { printf 'rehearse: %s\n' "$*" >&2; exit 1; }
# native <path>: the spelling a native Windows program wants (mixed form with a drive letter); unchanged elsewhere
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
# sums_check <dir>: the LF SHA256SUMS passes the platform's own checker (sha256sum -c, or shasum -a 256 -c on macOS)
sums_check() { ( cd "$1" && if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi ); }
tools_bin() { if [ -d "$TOOLS_VENV/Scripts" ]; then echo "$TOOLS_VENV/Scripts"; else echo "$TOOLS_VENV/bin"; fi; }
# Scratch directories are registered in a list file and removed when the script ends (REHEARSE_KEEP=1 keeps them for a post-mortem). Only a
# directory that this script made, whose name matches the mktemp pattern below, is ever removed.
WORKLIST=$(mktemp "${TMPDIR:-/tmp}/pagetriage-rehearsal-list.XXXXXX")
cleanup() {
  if [ "${REHEARSE_KEEP:-0}" = 1 ]; then echo "kept: the scratch directories are listed in $WORKLIST"; return 0; fi
  local d
  while IFS= read -r d; do
    case "$d" in */pagetriage-rehearsal.??????) if [ -d "$d" ]; then rm -r "$d"; fi ;; esac
  done < "$WORKLIST"
  rm -f "$WORKLIST"
}
trap cleanup EXIT
work_dir() { # a fresh scratch directory outside the checkout: $RUNNER_TEMP on CI, the system temp elsewhere
  local base=${RUNNER_TEMP:-${TMPDIR:-/tmp}} d
  # Git Bash: RUNNER_TEMP is a Windows path (D:\a\_temp); every path in this script is the POSIX spelling, converted by native() for Windows programs
  if command -v cygpath >/dev/null 2>&1; then base=$(cygpath -u "$base"); fi
  d=$(mktemp -d "${base%/}/pagetriage-rehearsal.XXXXXX")
  echo "$d" >> "$WORKLIST"
  echo "$d"
}

# ---------------------------------------------------------------------------------------------------
phase_tools() {
  log "tools: maturin, uv and ziglang from tools/ci/requirements.txt, installed by hash into $TOOLS_VENV"
  if [ ! -d "$TOOLS_VENV" ]; then
    "$PY" -m venv "$TOOLS_VENV"
  fi
  "$(tools_bin)/python" -m pip install --require-hashes --no-deps --only-binary=:all: -r tools/ci/requirements.txt
  "$(tools_bin)/maturin" --version
}

# ---------------------------------------------------------------------------------------------------
phase_build() {
  [ -x "$(tools_bin)/maturin" ] || [ -x "$(tools_bin)/maturin.exe" ] || phase_tools
  export PATH="$(tools_bin):$PATH"
  mkdir -p "$REPORT"
  ( . scripts/remap-flags.sh; echo "RUSTFLAGS: $RUSTFLAGS" > "$REPORT/rustflags.txt" )

  # The artefacts are built by the script that the publish workflow's build job runs: the rehearsal builds exactly what a release builds.
  BUILD_SET=all RELEASE_DIR="$DIST" PAGETRIAGE_TOOLS_VENV="$TOOLS_VENV" bash scripts/release/build-artefacts.sh

  log "command-line binary (release profile; the README quick start runs this one)"
  ( . scripts/remap-flags.sh; cargo build --release --locked -p pagetriage-cli )

  if [ -f "$DIST/pagetriage-$PYVER.tar.gz" ]; then
    log "a wheel built from the sdist alone (no checkout around it), --locked"
    local w; w=$(work_dir)
    tar -xzf "dist/sdist/pagetriage-$PYVER.tar.gz" -C "$w"
    ( cd "$w/pagetriage-$PYVER" && CARGO_TARGET_DIR="$w/target" maturin build --release --locked -o "$w/wheel" )
    mkdir -p "$REPORT/sdist-wheel"
    cp "$w"/wheel/*.whl "$REPORT/sdist-wheel/"
    ls -l "$REPORT/sdist-wheel"
  fi

  log "the two crates packaged a second time, with the command publish.yml runs (cargo package --locked --no-verify): the .crate files must be byte-identical to the verified ones (S1-126, S1-131, TD-123)"
  local first="" second="" f dirty=""
  if [ "${REHEARSE_ALLOW_DIRTY:-0}" = 1 ]; then dirty="--allow-dirty"; fi
  for f in "$DIST/pagetriage-core-$VERSION.crate" "$DIST/pagetriage-cli-$VERSION.crate"; do
    [ -f "$f" ] || die "the build did not produce $f"
    first="$first$(sha256_of "$f")  $(basename "$f")
"
  done
  rm -f target/package/*.crate
  # The second run only has to produce the same bytes; the first one already built every crate from its tarball (verification).
  # shellcheck disable=SC2086
  cargo package --locked --no-verify -p pagetriage-core -p pagetriage-cli $dirty
  for f in target/package/pagetriage-core-"$VERSION".crate target/package/pagetriage-cli-"$VERSION".crate; do
    second="$second$(sha256_of "$f")  $(basename "$f")
"
  done
  printf 'run 1:\n%srun 2:\n%s' "$first" "$second" | tee "$REPORT/crate-reproducibility.txt"
  if [ "$first" = "$second" ]; then
    echo "crate reproducibility: identical bytes in two runs ($OSNAME)" | tee -a "$REPORT/crate-reproducibility.txt"
    echo "crate reproducibility: the --no-verify bytes equal the verified bytes ($OSNAME): run 1 is cargo package --locked (it builds each crate from its tarball), run 2 is cargo package --locked --no-verify, the command the publish job re-runs" | tee -a "$REPORT/crate-reproducibility.txt"
  else die "the --no-verify cargo package run gave different .crate bytes from the verified run: the crates must leave the signed set (TD-123, S1-126); see $REPORT/crate-reproducibility.txt"; fi
}

# ---------------------------------------------------------------------------------------------------
dist_file() { # dist_file <glob-suffix>: the single file in dist-release matching pagetriage*<suffix>
  local f n=0 found=""
  for f in "$DIST"/$1; do [ -f "$f" ] && { found=$f; n=$((n+1)); }; done
  [ "$n" = 1 ] || die "want exactly one $1 in $DIST, found $n"
  printf '%s' "$found"
}

phase_install() {
  [ -d "$DIST" ] || die "$DIST does not exist: run the build phase first"
  mkdir -p "$REPORT"
  local golden="$REPO/tests/golden" w; w=$(work_dir)
  log "scratch directory for the install checks (outside the checkout): $w"
  case "$w" in "$REPO"/*) die "the scratch directory is inside the checkout" ;; esac

  # Every artefact is hashed first; the install below uses the file in dist-release, whose hash is the one in the report.
  ( cd "$DIST" && for f in *; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done ) > "$REPORT/artefacts.sha256"
  cat "$REPORT/artefacts.sha256"

  log "npm tarball: fresh project, offline, fresh cache, --ignore-scripts"
  local tgz; tgz=$(dist_file "airplanemode-pagetriage-*.tgz")
  mkdir -p "$w/npm-project" "$w/npm-cache"
  ( cd "$w/npm-project"
    npm init -y > /dev/null
    npm_config_offline=true npm_config_cache="$(native "$w/npm-cache")" npm install --ignore-scripts --no-audit --no-fund "$(native "$tgz")" > npm-install.log 2>&1 || { cat npm-install.log; exit 1; }
    ls node_modules node_modules/@airplanemode
    node "$(native "$REPO/scripts/release/check-installed.cjs")" "$(native "$golden")" "$(native "$w/npm-project")" ) 2>&1 | tee "$REPORT/install-npm.log" || die "the npm install check failed"

  log "wheel: fresh venv named .venv, PIP_NO_INDEX=1, pip install --no-index --no-deps"
  local whl; whl=$(dist_file "pagetriage-$PYVER-cp39-abi3-*.whl")
  # tests/python/check_wheel.py: tags compared as expanded sets, licences, NOTICE, sizes, no scripts (python -I: no site, no cwd)
  "$PY" -I tests/python/check_wheel.py "$whl" "$PYVER" 2>&1 | tee "$REPORT/check-wheel.log" || die "tests/python/check_wheel.py failed on $(basename "$whl")"
  check_wheel_install "$whl" "$w/wheel-project" "$golden" "$REPORT/install-wheel.log"

  if [ -f "$DIST/pagetriage-$PYVER.tar.gz" ]; then
    log "the wheel built from the sdist alone: the same checks"
    local sw; sw=$(ls "$REPORT"/sdist-wheel/*.whl)
    check_wheel_install "$sw" "$w/sdist-wheel-project" "$golden" "$REPORT/install-sdist-wheel.log"
  fi

  log "command-line tool: built from the packaged .crate files, offline; run by absolute path under the scratch root"
  # The packaged crates are the ones in dist-release (the ones that get signed), not target/package.
  bash scripts/release/install-crate-offline.sh "$DIST" "$w/cli" "$w/crate-work" 2>&1 | tee "$REPORT/install-cli.log" || die "the CLI install from the packaged crates failed"
  local cli="$w/cli/bin/pagetriage"; [ -f "$cli" ] || cli="$w/cli/bin/pagetriage.exe"
  [ -f "$cli" ] || die "no installed CLI under $w/cli/bin"
  cli=$(cd "$(dirname "$cli")" && pwd)/$(basename "$cli")
  case "$cli" in "$REPO"/*) die "the CLI under test is inside the checkout: $cli" ;; esac
  echo "cli path: $cli (not under the checkout $REPO)" | tee -a "$REPORT/install-cli.log"
  "$cli" structure "$golden/pdf/native_latin.pdf" > "$w/cli-structure.json"
  cmp "$w/cli-structure.json" "$golden/pdf_expected/native_latin.json" || die "CLI structure output differs from the golden report"
  echo "ok   structure on the golden PDF native_latin.pdf is byte-equal to its golden report" | tee -a "$REPORT/install-cli.log"
  cp "$w/crate-work/cargo.plain.log" "$REPORT/install-cli-cargo.log" 2>/dev/null || true
}

check_wheel_install() { # check_wheel_install <wheel> <project-dir> <golden-dir> <log>
  local whl=$1 proj=$2 golden=$3 lg=$4
  mkdir -p "$proj"
  ( cd "$proj"
    "$PY" -m venv .venv
    local vb=.venv/bin; [ -d .venv/Scripts ] && vb=.venv/Scripts
    PIP_NO_INDEX=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$vb/python" -m pip install --no-index --no-deps "$(native "$whl")"
    "$vb/python" -I "$(native "$REPO/scripts/release/check-installed.py")" "$(native "$golden")" "$(native "$proj/.venv")" ) 2>&1 | tee "$lg" || die "the wheel install check failed ($(basename "$whl"))"
}

# ---------------------------------------------------------------------------------------------------
# The rehearsal with the vendored release-tool. Every refusal proof checks the exact exit code, the exact first line of
# stderr and, for exit 3, the reason in the JSON on stdout. An I/O error (exit 1), a crash, a signal or a missing tool is
# never a refusal: it is a different exit code or a different line, so the proof fails.
PROOFS=0
tool() { node "$(native "$TOOL_PATH")" "$@"; }
# prove <name> <want exit> <want first stderr line; a trailing * means prefix> <want JSON reason or -> <tool args...>
prove() {
  local name=$1 want_rc=$2 want_first=$3 want_reason=$4; shift 4
  local so se rc first reason
  so=$(mktemp "${TMPDIR:-/tmp}/rehearse-out.XXXXXX"); se=$(mktemp "${TMPDIR:-/tmp}/rehearse-err.XXXXXX")
  set +e; tool "$@" > "$so" 2> "$se"; rc=$?; set -e
  first=$(head -n 1 "$se" | tr -d '\r')
  reason=$(sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p' "$so" | head -1)
  local good=1
  [ "$rc" = "$want_rc" ] || good=0
  case "$want_first" in
    *'*') [ "${first#"${want_first%\*}"}" != "$first" ] || good=0 ;;
    *) [ "$first" = "$want_first" ] || good=0 ;;
  esac
  [ "$want_reason" = "-" ] || [ "$reason" = "$want_reason" ] || good=0
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$rc" "$first" "${reason:--}" "$([ "$good" = 1 ] && echo proved || echo FAILED)" >> "$REPORT/refusals.tsv"
  if [ "$good" = 1 ]; then
    echo "proved: $name -> exit $rc, '$first'${reason:+, reason $reason}"
    PROOFS=$((PROOFS+1))
  else
    echo "FAILED: $name: want exit $want_rc, first stderr line '$want_first', reason '$want_reason'; got exit $rc, '$first', reason '${reason:--}'" >&2
    head -n 5 "$se" | sed -e 's/^/  stderr: /' >&2
    rm -f "$so" "$se"
    die "refusal proof failed: $name"
  fi
  rm -f "$so" "$se"
}

phase_sign_core() {
  [ -d "$DIST" ] || die "$DIST does not exist"
  [ -f "$TOOL_PATH" ] || die "the release tool $TOOL does not exist (a missing tool is a failure, never a pass)"
  mkdir -p "$REPORT"
  : > "$REPORT/refusals.tsv"
  [ -n "${SOURCE_DATE_EPOCH:-}" ] || SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || date -u +%s)
  export SOURCE_DATE_EPOCH
  log "release manifest $MANIFEST_ID $VERSION (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH), SHA256SUMS"
  rm -f "$DIST/release-manifest.json" "$DIST/SHA256SUMS"
  tool manifest --dir "$(native "$DIST")" --id "$MANIFEST_ID" --version "$VERSION" --licence "$LICENCE" --publisher rehearsal
  tool sums --dir "$(native "$DIST")"
  log "sign with the published RFC 8032 TEST key (rehearsal only; the tool prints its own banner)"
  tool sign --dir "$(native "$DIST")" --test-key rfc8032-1
  log "SHA256SUMS: LF only, one line per artefact, passes the platform checker"
  if tr -d '\n' < "$DIST/SHA256SUMS" | grep "$(printf '\r')" >/dev/null; then die "SHA256SUMS holds a carriage return"; fi
  local entries lines
  entries=$(ls "$DIST" | grep -vc -e '^release-manifest.json$' -e '^SHA256SUMS$' || true)
  lines=$(wc -l < "$DIST/SHA256SUMS" | tr -d ' ')
  [ "$entries" = "$lines" ] || die "SHA256SUMS has $lines lines for $entries artefacts"
  sums_check "$DIST" | tee "$REPORT/sha256sum-check.log"

  log "verification with the explicit test-key flag succeeds, and says it used the test key"
  local so se; so=$(mktemp "${TMPDIR:-/tmp}/rehearse-out.XXXXXX"); se=$(mktemp "${TMPDIR:-/tmp}/rehearse-err.XXXXXX")
  set +e; tool verify --dir "$(native "$DIST")" --expect-id "$MANIFEST_ID" --trust-test-key --allow-test-key > "$so" 2> "$se"; local rc=$?; set -e
  cat "$so"; cat "$se" >&2
  [ "$rc" = 0 ] || die "verify with --allow-test-key exited $rc, want 0"
  grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"ok"' "$so" && grep -Eq '"testKey"[[:space:]]*:[[:space:]]*true' "$so" || die "verify did not print verdict ok with testKey true"
  grep -q 'VERIFIED WITH THE PUBLISHED RFC 8032 TEST KEY' "$se" || die "verify did not print the test-key banner on stderr"
  printf 'verify-with-flag\t0\t%s\tok\tproved\n' "$(head -n 1 "$se" | tr -d '\r')" >> "$REPORT/refusals.tsv"
  PROOFS=$((PROOFS+1))
  rm -f "$so" "$se"

  log "refusal proofs (exact exit code, exact first stderr line, JSON reason)"
  local D; D=$(native "$DIST")
  prove "no-flag" 3 "refused: test_key_refused" test_key_refused verify --dir "$D" --expect-id "$MANIFEST_ID" --trust-test-key
  prove "production-trust-file-has-no-key" 3 "refused: no_trusted_key" no_trusted_key verify --dir "$D" --expect-id "$MANIFEST_ID" --trust-file "$(native "$REPO/docs/release-keys.json")"
  prove "expect-id-is-mandatory" 2 "usage: expect_id_required*" - verify --dir "$D" --trust-test-key --allow-test-key
  prove "flag-with-a-release-id" 2 "usage: test_key_flag_misuse*" - verify --dir "$D" --expect-id pagetriage-release --trust-test-key --allow-test-key
  prove "flag-with-a-trust-file" 2 "usage: test_key_flag_misuse*" - verify --dir "$D" --expect-id "$MANIFEST_ID" --trust-file "$(native "$REPO/docs/release-keys.json")" --allow-test-key
  prove "wrong-expect-id" 3 "refused: unexpected_id" unexpected_id verify --dir "$D" --expect-id other-rehearsal --trust-test-key --allow-test-key

  log "tampered artefact (one byte flipped in a copy) is refused"
  local w; w=$(work_dir)
  cp -R "$DIST" "$w/tampered"
  local victim; victim=$(ls "$w/tampered" | grep -v -e '^release-manifest.json$' -e '^SHA256SUMS$' | head -1)
  node -e 'const fs=require("fs");const fd=fs.openSync(process.argv[1],"r+");const b=Buffer.alloc(1);fs.readSync(fd,b,0,1,0);b[0]^=0xff;fs.writeSync(fd,b,0,1,0);fs.closeSync(fd)' "$(native "$w/tampered/$victim")"
  prove "tampered-artefact" 3 "refused: artifact_hash_mismatch" artifact_hash_mismatch verify --dir "$(native "$w/tampered")" --expect-id "$MANIFEST_ID" --trust-test-key --allow-test-key
  log "SHA256SUMS with CRLF endings (a copy) is refused"
  cp -R "$DIST" "$w/crlf"
  sed 's/$/\r/' "$DIST/SHA256SUMS" > "$w/crlf/SHA256SUMS"
  prove "crlf-sums" 3 "refused: sums_mismatch" sums_mismatch verify --dir "$(native "$w/crlf")" --expect-id "$MANIFEST_ID" --trust-test-key --allow-test-key

  log "a test key never signs a release id (R1): sign of a -release manifest is a usage error"
  mkdir -p "$w/relid"
  printf 'release id probe\n' > "$w/relid/probe.bin"
  tool manifest --dir "$(native "$w/relid")" --id pagetriage-release --version "$VERSION" --licence "$LICENCE" --publisher release
  prove "test-key-never-signs-a-release-id" 2 "usage: test_key_release_id*" - sign --dir "$(native "$w/relid")" --test-key rfc8032-1
  [ "$PROOFS" -ge 10 ] || die "only $PROOFS proofs ran"
  echo "rehearsal signed with the test key and verified: $PROOFS proofs, table in $REPORT/refusals.tsv"
}

# The self-test: a missing release tool, a tool that approves everything, and a tool that always fails with an I/O error must
# each turn the rehearsal red. Run before the rehearsal itself, in a scratch output root so nothing in dist-release changes.
selftest() {
  log "self-test: the rehearsal must fail with a missing tool, a tool that never refuses and a tool that always exits 1"
  local w; w=$(work_dir)
  mkdir -p "$w/out/dist-release"
  printf 'selftest artefact\n' > "$w/out/dist-release/pagetriage-selftest.tgz"
  # lenient.mjs runs the VENDORED tool (never RELEASE_TOOL, which may itself be a stub: that recursed once) and prints what it printed, but
  # always exits 0: a verifier that never refuses. It refuses to run inside itself, so it cannot recurse.
  printf 'import { spawnSync } from "node:child_process";\nif (process.env.REHEARSE_STUB_DEPTH) process.exit(1);\nspawnSync(process.execPath, [process.env.REAL_TOOL, ...process.argv.slice(2)], { stdio: "inherit", env: { ...process.env, REHEARSE_STUB_DEPTH: "1" } });\nprocess.exit(0);\n' > "$w/lenient.mjs"
  printf 'console.error("EIO"); process.exit(1)\n' > "$w/io.mjs"
  local t
  for t in "$w/does-not-exist.mjs" "$w/lenient.mjs" "$w/io.mjs"; do
    if REAL_TOOL="$REPO/scripts/release/release-tool.mjs" REHEARSE_OUT_ROOT="$w/out" RELEASE_TOOL="$t" SOURCE_DATE_EPOCH=0 bash "$0" sign-core > "$w/selftest.log" 2>&1; then
      die "self-test: the rehearsal PASSED with the tool $(basename "$t")"
    fi
    echo "ok   the rehearsal fails with $(basename "$t")"
  done
}

phase_sign() { selftest; phase_sign_core; }

# ---------------------------------------------------------------------------------------------------
phase_gate() {
  [ -d "$DIST" ] || die "$DIST does not exist"
  log "gate: dist-release/ holds only the manifest entries, release-manifest.json and SHA256SUMS"
  [ -f "$DIST/release-manifest.json" ] && [ -f "$DIST/SHA256SUMS" ] || die "release-manifest.json or SHA256SUMS is missing"
  local listed actual
  listed=$( { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(m.entries.map((e)=>e.url).join("\n"))' "$(native "$DIST/release-manifest.json")"; echo release-manifest.json; echo SHA256SUMS; } | sort )
  actual=$(ls "$DIST" | sort)
  [ "$listed" = "$actual" ] || { printf 'listed in the manifest:\n%s\nin the directory:\n%s\n' "$listed" "$actual" >&2; die "dist-release/ differs from the manifest entries plus the two files"; }
  [ -z "$(find "$DIST" -mindepth 1 -type d)" ] || die "dist-release/ holds a subdirectory"
  [ -z "$(find "$DIST" -type l)" ] || die "dist-release/ holds a symbolic link"
  case "$REPORT" in "$DIST"|"$DIST"/*) die "the report directory is inside the release directory" ;; esac
  local bad
  bad=$(ls -A "$DIST" | grep -iE '^\.npmrc$|^\.pypirc$|\.pem$|\.key$|\.der$|\.pkcs8$|seed|secret|\.env' || true)
  [ -z "$bad" ] || die "dist-release/ holds key or credential material by name: $bad"
  echo "ok   dist-release/ holds $(ls "$DIST" | wc -l | tr -d ' ') files, all listed, no key or credential name"

  log "gate: every .crate holds LICENSE-APACHE, LICENSE-MIT and NOTICE next to Cargo.toml (BUG-T3-S7-04)"
  local c stem why n=0
  for c in "$DIST"/*.crate; do
    [ -f "$c" ] || continue
    stem=$(basename "$c" .crate)
    why=$("$PY" -I scripts/release/check-crate.py "$(native "$c")" "$stem") || die "the crate $(basename "$c") is not complete: $why (it needs LICENSE-APACHE, LICENSE-MIT and NOTICE in $stem/)"
    echo "ok   ${why#ok: }"
    n=$((n+1))
  done
  [ "$n" -ge 1 ] || die "no .crate in $DIST: the crates are in the signed set"

  log "gate: no builder path in the wheels, the tarball and the sdist"
  local f
  for f in "$DIST"/*.whl "$DIST"/*.tgz "$DIST"/*.tar.gz; do
    [ -f "$f" ] || continue
    bash scripts/check-no-builder-paths.sh "$f"
  done
  log "gate: no plain release version in any artefact name (the release candidate is $VERSION)"
  if ls "$DIST" | sed -E 's/1\.0\.0(-rc\.[0-9]+|rc[0-9]+)//g' | grep -E '(^|[-_])1\.0\.0($|[-_.])' >/dev/null; then die "an artefact name reads the release version before the tag"; fi
  if [ "$OUT_ROOT" = "$REPO" ]; then bash tests/scripts/no-plain-1.0.0.sh | tail -3; fi
  echo "gate ok"
}

# ---------------------------------------------------------------------------------------------------
case "${1:-all}" in
  tools) phase_tools ;;
  build) phase_build ;;
  install) phase_install ;;
  sign) phase_sign ;;
  sign-core) phase_sign_core ;;
  gate) phase_gate ;;
  all) phase_build; phase_install; phase_sign; phase_gate ;;
  *) echo "usage: $0 [tools|build|install|sign|gate|all]" >&2; exit 2 ;;
esac
