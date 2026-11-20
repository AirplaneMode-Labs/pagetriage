#!/usr/bin/env bash
# Runs every script test; non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in package-npm-notice.sh installer.sh build-site-commit.sh build-wasm-guard.sh cargo-target-dir.sh release-manifest.sh crate-licences.sh path-leak-gate.sh build-site-notices.sh notice-cli.sh notice-core.sh wasm-api-doc.sh streams-doc.sh ci-policy.sh check-wheel-tags.sh remap-flags.sh version-forms.sh no-plain-1.0.0.sh readme-demo-link.sh issue-forms.sh quickstart.sh release-tool-vendored.sh release-doc.sh rehearse.sh publish-guard.sh deps-network-check.sh pipefail-grep-q.sh ci-policy-mutations.sh; do
  echo "== $t"
  bash "./$t" || rc=1
done
# Path-containment unit tests (path.win32 + a fake file system, plus real links). A missing node is a failure,
# not a skip: the same suite is what proves the Windows rules on a Mac.
echo "== confine.test.mjs"
if command -v node >/dev/null; then
  node --test ./confine.test.mjs || rc=1
else
  echo "FAIL - node not found: confine.test.mjs cannot run (Node 22 is required)"; rc=1
fi
exit $rc
