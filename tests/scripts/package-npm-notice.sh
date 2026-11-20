#!/usr/bin/env bash
# T3-S5-06: the npm package ships NOTICE next to LICENSE-MIT and LICENSE-APACHE (MIT texts of statically linked
# crates). Runs scripts/package-npm.sh in a scratch copy of the repo layout with the real dist/wasm build when present
# (otherwise a stub build in the scratch copy; the mode that ran is printed), then inspects the tarball. Nothing is published.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v npm >/dev/null || { fail "npm not found: package-npm.sh cannot be tested"; finish; exit 1; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir -p "$S/scripts"
cp "$SCRIPTS_DIR/package-npm.sh" "$SCRIPTS_DIR/check-no-builder-paths.sh" "$S/scripts/"
cp "$REPO/Cargo.toml" "$REPO/LICENSE-MIT" "$REPO/LICENSE-APACHE" "$REPO/NOTICE" "$REPO/README.md" "$S/"
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
if [ -f "$REPO/dist/wasm/nodejs/pagetriage_bg.wasm" ]; then
  echo "mode: real dist/wasm"
  mkdir -p "$S/dist/wasm" && cp -R "$REPO/dist/wasm/web" "$REPO/dist/wasm/nodejs" "$S/dist/wasm/"
else
  # A clean checkout (CI test job, no wasm build) has no dist/wasm: build a minimal stub inside the scratch copy only.
  echo "mode: stub dist/wasm (no real build present; stub lives in the scratch copy, never in the repo's dist/)"
  mkdir -p "$S/dist/wasm/web" "$S/dist/wasm/nodejs"
  for t in web nodejs; do
    printf '\000asm\001\000\000\000' > "$S/dist/wasm/$t/pagetriage_bg.wasm"
    printf 'export function version() { return "stub"; }\n' > "$S/dist/wasm/$t/pagetriage.js"
    printf 'export function version(): string;\n' > "$S/dist/wasm/$t/pagetriage.d.ts"
  done
  # The nodejs entry is what package-npm.sh runs after installing the tarball: blank page finding and a wrong-length throw.
  cat > "$S/dist/wasm/nodejs/pagetriage.js" <<'JS'
exports.version = () => "stub";
exports.analyse_page = (buf, _a, w, h) => {
  if (buf.length !== w * h) throw new Error("buffer length does not match width*height");
  return JSON.stringify({ findings: [{ kind: "blank_page" }] });
};
JS
fi
OUT=$(cd "$S" && bash scripts/package-npm.sh 2>&1); rc=$?
expect_eq "package-npm.sh exits 0" 0 "$rc"
# TD-108 (Sprint 7): the npm package is @airplanemode/pagetriage, so npm pack names the file airplanemode-pagetriage-<version>.tgz
# (a '/' in a scoped name becomes '-', the '@' is dropped); TD-107: the npm version is the SemVer of the release candidate.
. "$REPO/scripts/lib/version.sh"
WANT_VERSION=$(workspace_version "$REPO/Cargo.toml")
TGZ=$(ls "$S"/dist/npm/*.tgz 2>/dev/null | head -1)
expect_eq "exactly one tarball in dist/npm" 1 "$(ls "$S"/dist/npm/*.tgz 2>/dev/null | wc -l | tr -d ' ')"
expect_eq "the tarball is airplanemode-pagetriage-<version>.tgz" "airplanemode-pagetriage-$WANT_VERSION.tgz" "$(basename "$TGZ")"
# the first matching line, by awk and not grep -m1: a reader that stops early leaves tar writing to a closed pipe (tests/scripts/lib.sh, gq)
expect_eq "package.json name is @airplanemode/pagetriage" '"name": "@airplanemode/pagetriage",' "$(tar -xzOf "$TGZ" package/package.json | awk '/"name"/ && !n { print; n = 1 }' | sed 's/^ *//')"
expect_eq "package.json version is the workspace version" "\"version\": \"$WANT_VERSION\"," "$(tar -xzOf "$TGZ" package/package.json | awk '/"version"/ && !n { print; n = 1 }' | sed 's/^ *//')"
LIST=$(tar -tzf "$TGZ" 2>/dev/null)
for f in LICENSE-MIT LICENSE-APACHE NOTICE; do
  expect_eq "tarball lists package/$f" 1 "$(printf '%s\n' "$LIST" | grep -c "^package/$f$")"
done
expect_eq "package.json files list names NOTICE" 1 "$(tar -xzOf "$TGZ" package/package.json | grep -c '"NOTICE"')"
expect_eq "packed NOTICE equals the root NOTICE" "$(sha "$REPO/NOTICE")" "$(tar -xzOf "$TGZ" package/NOTICE > "$S/NOTICE.packed"; sha "$S/NOTICE.packed")"
finish
