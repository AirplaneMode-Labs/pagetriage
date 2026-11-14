#!/usr/bin/env bash
# Each published crate directory carries plain copies of the root LICENSE-MIT and LICENSE-APACHE,
# so `cargo package` puts them in the crate tarball (BUG-T2-S3-05).
set -uo pipefail
cd "$(dirname "$0")/../.."
rc=0
for c in pagetriage-core pagetriage-cli; do
  for f in LICENSE-MIT LICENSE-APACHE; do
    if cmp -s "$f" "crates/$c/$f"; then echo "ok   crates/$c/$f equals root $f"
    else echo "FAIL crates/$c/$f missing or differs from root $f"; rc=1; fi
  done
done
exit $rc
