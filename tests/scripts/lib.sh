#!/usr/bin/env bash
# Shared helpers for the script tests. Each test builds a scratch copy of the repository layout the
# script under test expects (scripts/, crates/pagetriage-wasm/Cargo.toml, stubs), so nothing touches the
# real working tree and no network call is made. SCRIPTS_DIR overrides where the scripts come from
# (used to run a test against the HEAD versions for the red log).
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPTS_DIR=${SCRIPTS_DIR:-$REPO/scripts}
FAILS=0
PASSES=0
ok()   { PASSES=$((PASSES+1)); echo "ok   - $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL - $1"; }
# expect_eq <name> <want> <got>
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
new_scratch() { SCRATCH=$(mktemp -d); mkdir -p "$SCRATCH/scripts" "$SCRATCH/crates/pagetriage-wasm" "$SCRATCH/bin"; cp "$REPO/crates/pagetriage-wasm/Cargo.toml" "$SCRATCH/crates/pagetriage-wasm/"; }
finish() { echo "$PASSES passed, $FAILS failed"; [ "$FAILS" -eq 0 ]; }
