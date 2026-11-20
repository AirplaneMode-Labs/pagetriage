#!/usr/bin/env bash
# Build the pagetriage sdist so that it builds `cargo build --locked` from its own Cargo.lock (S1-103, TD-09).
#
#   scripts/package-sdist.sh
#
# `maturin sdist` (1.16.0) writes a workspace manifest with two members (pagetriage-core and pagetriage-py) next to the
# repository's whole Cargo.lock, so the unpacked sdist cannot build --locked: cargo wants to drop the lock entries
# of pagetriage-cli, pagetriage-wasm and the crates only they use. scripts/prune-sdist-lock.py removes exactly those
# entries (no version or checksum changes), and this script then proves the result: it unpacks the sdist in scratch,
# runs `cargo build --locked -p pagetriage-py` there and checks that Cargo.lock came out byte-identical. It does not
# publish anything, and `maturin sdist` compiles nothing itself.
#
# Environment: SDIST_OUT (default dist/sdist, relative to the repository, or absolute) is where pagetriage-<version>.tar.gz
# is written (the PEP 440 version: pagetriage-1.0.0rc1.tar.gz for the release candidate); any pagetriage-*.tar.gz already there is removed first. SDIST_VERIFY=0 skips the cargo build. PAGETRIAGE_TOOLS_VENV (the hashed venv the CI wheels job makes from
# tools/ci/requirements.txt) or a maturin on PATH of exactly the pinned version in tools/ci/requirements.in is used
# first; otherwise the tool comes from `uvx maturin@<pin>`, pinned by version only (the local, unhashed path).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${SDIST_OUT:-dist/sdist}
case "$OUT" in
  ""|[A-Za-z]:*|*\\*|..|../*|*/..|*/../*) echo "error: SDIST_OUT must be a non-empty path without backslashes, drive letters or '..' segments (got '$OUT')" >&2; exit 2 ;;
esac
# maturin writes the PEP 440 form of the version into the sdist's name (1.0.0-rc.1 -> pagetriage-1.0.0rc1.tar.gz, TD-107)
# shellcheck source=lib/version.sh
. scripts/lib/version.sh
VERSION=$(workspace_version Cargo.toml)
PYVER=$(py_version "$VERSION")
MATURIN_VERSION=$(sed -n 's/^maturin==\(.*\)$/\1/p' tools/ci/requirements.in | head -1)
[ -n "$MATURIN_VERSION" ] || { echo "error: tools/ci/requirements.in does not pin maturin" >&2; exit 1; }

if [ -n "${PAGETRIAGE_TOOLS_VENV:-}" ]; then
  if [ -d "$PAGETRIAGE_TOOLS_VENV/Scripts" ]; then TOOLS_BIN=$PAGETRIAGE_TOOLS_VENV/Scripts; else TOOLS_BIN=$PAGETRIAGE_TOOLS_VENV/bin; fi
  [ -d "$TOOLS_BIN" ] || { echo "error: PAGETRIAGE_TOOLS_VENV ($PAGETRIAGE_TOOLS_VENV) has no bin or Scripts directory" >&2; exit 1; }
  MATURIN=("$(cd "$TOOLS_BIN" && pwd -P)/maturin")
  FROM="the hashed venv $PAGETRIAGE_TOOLS_VENV"
elif command -v maturin >/dev/null 2>&1 && [ "$(maturin --version)" = "maturin $MATURIN_VERSION" ]; then
  MATURIN=(maturin)
  FROM="maturin $MATURIN_VERSION on PATH"
else
  MATURIN=(uvx "maturin@$MATURIN_VERSION")
  FROM="uvx, pinned by version only"
fi
GOT=$("${MATURIN[@]}" --version)
[ "$GOT" = "maturin $MATURIN_VERSION" ] || { echo "error: got '$GOT', want 'maturin $MATURIN_VERSION'" >&2; exit 1; }
echo "== tools: maturin $MATURIN_VERSION (from $FROM)"

mkdir -p "$OUT"
# Only sdists of this package are removed, and only from the output directory.
find "$OUT" -maxdepth 1 -name 'pagetriage-*.tar.gz' -type f -delete
echo "== maturin sdist (pagetriage $VERSION)"
"${MATURIN[@]}" sdist -m crates/pagetriage-py/Cargo.toml -o "$OUT"
SDIST=$OUT/pagetriage-$PYVER.tar.gz
[ -f "$SDIST" ] || { echo "error: $SDIST was not written" >&2; exit 1; }

echo "== prune the sdist's Cargo.lock to the packages its own workspace needs"
python3 -I scripts/prune-sdist-lock.py "$SDIST"

if [ "${SDIST_VERIFY:-1}" != 0 ]; then
  echo "== verify: unpack, cargo build --locked -p pagetriage-py, Cargo.lock unchanged"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/pagetriage-sdist-verify.XXXXXX")
  WORK=$(cd "$WORK" && pwd -P)
  cleanup() { case "$WORK" in /*/pagetriage-sdist-verify.??????) rm -rf "$WORK" ;; esac; }
  trap cleanup EXIT
  tar -xzf "$SDIST" -C "$WORK"
  cp "$WORK/pagetriage-$PYVER/Cargo.lock" "$WORK/Cargo.lock.before"
  ( cd "$WORK/pagetriage-$PYVER" && CARGO_TARGET_DIR="$WORK/target" cargo build --locked -p pagetriage-py )
  cmp "$WORK/pagetriage-$PYVER/Cargo.lock" "$WORK/Cargo.lock.before" || { echo "error: cargo changed the sdist's Cargo.lock" >&2; exit 1; }
  echo "ok: the sdist builds --locked from its own Cargo.lock"
fi
echo "sdist: $SDIST ($(wc -c < "$SDIST" | tr -d ' ') bytes)"
