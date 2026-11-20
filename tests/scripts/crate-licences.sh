#!/usr/bin/env bash
# Each published crate directory carries plain copies of the root LICENSE-MIT and LICENSE-APACHE,
# so `cargo package` puts them in the crate tarball (BUG-T2-S3-05), and a NOTICE of its own (BUG-T3-S7-04): the packaged .crate
# is part of the signed set, and rehearse.sh's gate requires all three files inside every .crate.
set -uo pipefail
cd "$(dirname "$0")/../.."
rc=0
for c in pagetriage-core pagetriage-cli; do
  for f in LICENSE-MIT LICENSE-APACHE; do
    if cmp -s "$f" "crates/$c/$f"; then echo "ok   crates/$c/$f equals root $f"
    else echo "FAIL crates/$c/$f missing or differs from root $f"; rc=1; fi
  done
done
for c in pagetriage-core pagetriage-cli; do
  if [ -s "crates/$c/NOTICE" ] && grep -q "Airplane Mode Labs pagetriage" "crates/$c/NOTICE"; then echo "ok   crates/$c/NOTICE exists and starts from the project notice"
  else echo "FAIL crates/$c/NOTICE is missing or is not the project notice"; rc=1; fi
done
exit $rc
