#!/usr/bin/env bash
# Build the release artefacts of pagetriage into one flat directory. The release rehearsal (scripts/release/rehearse.sh, CI job
# release-rehearsal) and the publish workflow's build job both call this script, so the rehearsal builds exactly what a release builds
# (Sprint 7, TD-106; D2-02, D2-03). It builds nothing but artefacts and signs and publishes nothing.
#
#   BUILD_SET=all|wheel RELEASE_DIR=<dir> bash scripts/release/build-artefacts.sh
#
#   all    (default; the Linux leg) the npm tarball (the PDF-enabled WebAssembly build), the wheel, the sdist (Linux only, or anywhere with REHEARSE_SDIST=1) and the two
#          crates, `cargo package --locked -p pagetriage-core -p pagetriage-cli` (one invocation: the CLI's dependency on the core crate
#          resolves to the packaged core through cargo's local overlay registry, never to crates.io)
#   wheel  the wheel only (the macOS and Windows legs of the publish workflow)
#
# RELEASE_DIR (default dist-release under the repository) receives the artefacts and nothing else: it is emptied first. Tools come from the
# hashed venv PAGETRIAGE_TOOLS_VENV (default tools-venv; the caller installs it by hash, or scripts/release/rehearse.sh tools does).
# Every cargo and maturin call is --locked; builds use the path-remap flags so that no builder path ends up in an artefact. On Linux the wheel
# is built through zig for the manylinux_2_17 tag. REHEARSE_ALLOW_DIRTY=1 (local runs only) lets cargo package accept an uncommitted tree.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$(pwd)
# shellcheck source=../lib/version.sh
. scripts/lib/version.sh
VERSION=$(workspace_version Cargo.toml)
PYVER=$(py_version "$VERSION")
SET=${BUILD_SET:-all}
case "$SET" in all|wheel) ;; *) echo "error: BUILD_SET must be all or wheel (got '$SET')" >&2; exit 2 ;; esac
RELEASE_DIR=${RELEASE_DIR:-$REPO/dist-release}
TOOLS_VENV=${PAGETRIAGE_TOOLS_VENV:-tools-venv}
case "$TOOLS_VENV" in /*|[A-Za-z]:*) ;; *) TOOLS_VENV=$REPO/$TOOLS_VENV ;; esac
if [ -d "$TOOLS_VENV/Scripts" ]; then TOOLS_BIN=$TOOLS_VENV/Scripts; else TOOLS_BIN=$TOOLS_VENV/bin; fi
[ -x "$TOOLS_BIN/maturin" ] || [ -x "$TOOLS_BIN/maturin.exe" ] || { echo "error: no maturin under $TOOLS_BIN (install tools/ci/requirements.txt by hash first)" >&2; exit 1; }
export PATH="$TOOLS_BIN:$PATH"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) OSNAME=windows ;; Darwin) OSNAME=macos ;; *) OSNAME=linux ;; esac
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
log() { printf '== %s\n' "$*"; }

# Every release build uses the time of the commit as SOURCE_DATE_EPOCH unless the caller sets one (publish.yml's build job used to export it itself;
# the rehearsal builds now do the same), so that two builds of the same commit are comparable byte for byte: the owner compares the publish
# candidates with an independent build of the same commit before signing (docs/RELEASING.md, step 12; S1-135).
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || true); fi
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then export SOURCE_DATE_EPOCH; echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (the commit time unless the caller set one)"; fi

rm -rf "$RELEASE_DIR"; mkdir -p "$RELEASE_DIR"

if [ "$SET" = all ]; then
  log "npm tarball (the PDF-enabled WebAssembly build: analyse_pdf_structure is what the quick start calls)"
  PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf bash scripts/build-wasm.sh
  WASM_OUT=dist/wasm-pdf bash scripts/package-npm.sh
  cp "dist/npm/airplanemode-pagetriage-$VERSION.tgz" "$RELEASE_DIR/"
fi

log "wheel ($OSNAME)"
rm -rf dist/wheels
( . scripts/remap-flags.sh
  if [ "$OSNAME" = linux ]; then
    maturin build --release --locked --zig --compatibility manylinux_2_17 -m crates/pagetriage-py/Cargo.toml -o dist/wheels
  else
    maturin build --release --locked -m crates/pagetriage-py/Cargo.toml -o dist/wheels
  fi )
ls -l dist/wheels
cp dist/wheels/pagetriage-"$PYVER"-cp39-abi3-*.whl "$RELEASE_DIR/"

if [ "$SET" = all ]; then
  if [ "$OSNAME" = linux ] || [ "${REHEARSE_SDIST:-0}" = 1 ]; then
    log "sdist, built --locked from its own Cargo.lock; the repository's Cargo.lock must not change"
    before=$(sha256_of Cargo.lock)
    SDIST_OUT=dist/sdist PAGETRIAGE_TOOLS_VENV="$TOOLS_VENV" bash scripts/package-sdist.sh
    after=$(sha256_of Cargo.lock)
    [ "$before" = "$after" ] || { echo "error: the repository's Cargo.lock changed while building the sdist" >&2; exit 1; }
    cp "dist/sdist/pagetriage-$PYVER.tar.gz" "$RELEASE_DIR/"
  fi
  log "the two published crates, packaged from this tree (cargo package --locked, verified by building each from its tarball)"
  dirty=""
  if [ "${REHEARSE_ALLOW_DIRTY:-0}" = 1 ]; then dirty="--allow-dirty"; fi
  rm -rf target/package
  # `cargo package --workspace` would also package and build the two publish = false crates (pagetriage-py, pagetriage-wasm), which nothing
  # signs or publishes; -p names exactly the crates that are published, in one invocation.
  # shellcheck disable=SC2086
  cargo package --locked -p pagetriage-core -p pagetriage-cli $dirty
  cp "target/package/pagetriage-core-$VERSION.crate" "target/package/pagetriage-cli-$VERSION.crate" "$RELEASE_DIR/"
fi
log "$RELEASE_DIR holds:"
ls -l "$RELEASE_DIR"
