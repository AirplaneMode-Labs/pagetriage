#!/usr/bin/env bash
# Dry runs of the publish commands (Sprint 7, D2-03; TD-105): what `publish.yml` would run, run for real but with --dry-run, on the artefacts of
# the release rehearsal in dist-release/. Nothing is uploaded, no token is read or needed, no registry is written. CI runs it in every
# release-rehearsal leg; the owner can run it on a laptop. A real publish is only ever the owner's dispatch of publish.yml.
#
#   bash scripts/release/publish-dry-run.sh
#
#   1. publish-guard.sh derives the npm dist-tag (alpha, beta or rc, or latest) and the PEP 440 version from the workspace version;
#   2. npm publish --dry-run of the tarball with the flags publish.yml uses (--access public --ignore-scripts --tag), apart from --provenance,
#      which needs the OIDC token that only the publish job has;
#   3. tests/python/check_wheel.py and a METADATA check on every wheel;
#   4. the crates: `cargo package --locked --no-verify -p pagetriage-core -p pagetriage-cli`, the publish job's own command, whose bytes must equal the
#      rehearsal's crates in dist-release/ (and the signed digests when the rehearsal has signed them), then `cargo publish --dry-run --locked --no-verify`
#      for the two crates as one unit (the CLI never looks the core crate up on crates.io: cargo's local overlay registry supplies the packaged core).
# Environment: REHEARSE_OUT_ROOT (default: the repository) holds dist-release/; REHEARSE_ALLOW_DIRTY=1 passes --allow-dirty (local runs only).
# There is no switch that changes the cargo commands: the dry run runs the commands the publish job runs.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$(pwd)
# shellcheck source=../lib/version.sh
. scripts/lib/version.sh
VERSION=$(workspace_version Cargo.toml)
PYVER=$(py_version "$VERSION")
DIST=${REHEARSE_OUT_ROOT:-$REPO}/dist-release
PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
die() { echo "publish-dry-run: $*" >&2; exit 1; }
log() { printf '== %s\n' "$*"; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
[ -d "$DIST" ] || die "$DIST does not exist: run scripts/release/rehearse.sh build first"

log "the dist-tag and the PEP 440 version, from the workspace version $VERSION"
TAG=$(bash scripts/release/publish-guard.sh dist-tag "$VERSION")
GOTPY=$(bash scripts/release/publish-guard.sh py-version "$VERSION")
[ "$GOTPY" = "$PYVER" ] || die "publish-guard.sh says the PEP 440 version is $GOTPY, scripts/lib/version.sh says $PYVER"
echo "npm dist-tag: $TAG; wheel and sdist version: $PYVER"

log "npm publish --dry-run of the tarball (the flags of publish.yml, without --provenance)"
TGZ=$DIST/airplanemode-pagetriage-$VERSION.tgz
[ -f "$TGZ" ] || die "$TGZ not found"
# env -u: no registry credential that a runner might carry can reach the dry run. A leading ./ keeps npm from reading the path as a GitHub shorthand.
NPMLOG=$(mktemp "${TMPDIR:-/tmp}/pagetriage-npm-dry-run.XXXXXX")
( cd "$DIST" && env -u NODE_AUTH_TOKEN -u NPM_TOKEN -u CARGO_REGISTRY_TOKEN npm publish "./airplanemode-pagetriage-$VERSION.tgz" --dry-run --access public --ignore-scripts --tag "$TAG" ) > "$NPMLOG" 2>&1 || { cat "$NPMLOG"; rm -f "$NPMLOG"; die "npm publish --dry-run failed"; }
tail -8 "$NPMLOG"
grep -q "@airplanemode/pagetriage@$VERSION" "$NPMLOG" || { rm -f "$NPMLOG"; die "the npm dry run did not name @airplanemode/pagetriage@$VERSION"; }
grep -q "with tag $TAG" "$NPMLOG" || { rm -f "$NPMLOG"; die "the npm dry run did not say it would publish with tag $TAG"; }
rm -f "$NPMLOG"

log "every wheel: tests/python/check_wheel.py and the METADATA fields PyPI reads"
n=0
for w in "$DIST"/pagetriage-"$PYVER"-cp39-abi3-*.whl; do
  [ -f "$w" ] || continue
  n=$((n+1))
  "$PY" -I tests/python/check_wheel.py "$w" "$PYVER" | tail -3
  "$PY" -I - "$w" "$PYVER" <<'PYEOF'
import sys, zipfile
wheel, version = sys.argv[1:3]
with zipfile.ZipFile(wheel) as z:
    meta = [n for n in z.namelist() if n.endswith(".dist-info/METADATA")]
    assert len(meta) == 1, meta
    text = z.read(meta[0]).decode("utf-8")
head = text.split("\n\n", 1)[0]
fields = {}
for line in head.splitlines():
    k, _, v = line.partition(": ")
    fields.setdefault(k, v)
assert fields.get("Name") == "pagetriage", fields.get("Name")
assert fields.get("Version") == version, (fields.get("Version"), version)
assert fields.get("Requires-Python") == ">=3.9", fields.get("Requires-Python")
assert fields.get("License-Expression") == "MIT OR Apache-2.0", fields.get("License-Expression")
assert fields.get("Summary"), "no Summary"
assert "Description-Content-Type" in fields, "no Description-Content-Type"
body = text.split("\n\n", 1)[1] if "\n\n" in text else ""
assert "Not published yet" in body or "not published" in body.lower(), "the long description lost the 'not published' sentence"
print("metadata ok:", fields["Name"], fields["Version"], fields["License-Expression"], fields["Requires-Python"])
PYEOF
done
[ "$n" -ge 1 ] || die "no wheel named pagetriage-$PYVER-cp39-abi3-*.whl in $DIST"

log "the crates, as publish.yml handles them: the same package command, the same bytes as the rehearsal's, then cargo publish --dry-run with the same flags"
DIRTY=""
if [ "${REHEARSE_ALLOW_DIRTY:-0}" = 1 ]; then DIRTY=--allow-dirty; fi
# The publish job re-packages with `cargo package --locked --no-verify` (verification already ran when the crates were built) and compares the
# digests with the signed manifest. Here the comparison is with the crates of the rehearsal in dist-release/, byte for byte, and, when the
# rehearsal has signed them, with the manifest through the same publish-guard.sh crate-digests the publish job runs (S1-126, S1-131).
rm -rf target/package
# shellcheck disable=SC2086
cargo package --locked --no-verify $DIRTY -p pagetriage-core -p pagetriage-cli
for f in "pagetriage-core-$VERSION.crate" "pagetriage-cli-$VERSION.crate"; do
  [ -f "$DIST/$f" ] || die "$DIST/$f not found"
  cmp -s "$DIST/$f" "target/package/$f" || die "the re-packaged $f differs from the one the rehearsal built: the crates cannot stay in the signed set (TD-123)"
  echo "ok: the re-packaged $f is byte-identical to the rehearsal's"
done
if [ -f "$DIST/release-manifest.json" ]; then
  GUARD_VERSION="$VERSION" bash scripts/release/publish-guard.sh crate-digests "$(native "$DIST")" target/package
fi
# shellcheck disable=SC2086
env -u NODE_AUTH_TOKEN -u NPM_TOKEN -u CARGO_REGISTRY_TOKEN cargo publish --dry-run --locked --no-verify $DIRTY -p pagetriage-core -p pagetriage-cli
echo "publish dry run ok: nothing was uploaded"
