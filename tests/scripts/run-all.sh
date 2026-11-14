#!/usr/bin/env bash
# Runs every script test; non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in installer.sh build-site-commit.sh build-wasm-guard.sh release-manifest.sh crate-licences.sh path-leak-gate.sh build-site-notices.sh; do
  echo "== $t"
  bash "./$t" || rc=1
done
exit $rc
