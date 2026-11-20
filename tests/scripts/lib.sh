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

# ---- grep in a pipeline under pipefail (CI run 44656239981) ----------------------------------------------------------------
# `producer | grep -q pattern` exits at the first match, so a producer that is still writing meets a closed pipe: it is killed by SIGPIPE (status 141) or, where
# SIGPIPE is ignored, gets EPIPE and exits non-zero, and `set -o pipefail` makes the whole pipeline fail although grep found the text. Whether the producer is
# still writing depends on the buffer size (4096 bytes for a pipe on Linux) and on scheduling, so it is a race: a run can win it and a Mac run proves nothing.
# The run that lost it: ci-policy.sh asked
#     job_text "$CI" determinism | grep -qE '^    permissions:'
# job_text is awk; the text of the determinism job has been over 4096 bytes since 1a6a244 (4309; 5399 now) and the match is on its third line, so awk's second
# block meets a pipe grep -q has closed, and the policy said "job determinism sets no permissions" about a job that sets them (the log shows no message from awk).
# Use gq in a pipeline: the arguments of grep without -q (and without -m, which stops early the same way); it reads all of its input and prints nothing, so its
# status is 0 for a match and 1 for none. In a script that does not source this file (scripts/, scripts/release/) write `grep ... >/dev/null`.
# tests/scripts/pipefail-grep-q.sh reproduces the failure on the real job text and refuses a new `| grep -q`.
gq() { grep "$@" >/dev/null; }
