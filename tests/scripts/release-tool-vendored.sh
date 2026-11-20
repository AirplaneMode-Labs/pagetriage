#!/usr/bin/env bash
# TD-103, TD-104, Sprint 7: scripts/release/release-tool.mjs is runtime's release tool (spec release 0.6.1), vendored byte for byte.
# This test proves, without reading any sibling repository:
#   1. VENDORED.json is {source, specRelease "0.6.1", sha256}, and sha256 is the digest of the file on disk;
#   2. the tool and VENDORED.json are '-text' in .gitattributes, and a clone made with core.autocrlf=true has the same digest
#      (with a control: the same files without the attribute do change under core.autocrlf=true);
#   3. the vendored vectors (tests/vectors/release) match the listing digest recorded beside them;
#   4. every case of release.json gives the expected exit code, first stderr line and reason through the vendored copy, run in a
#      scratch tree that holds only the tool, the vectors and the runner (no sibling repository can be read);
#   5. scripts/release-manifest.mjs and `release-tool manifest` write byte-identical manifests for the id pagetriage-release.
# TOOL_FILE and VECTORS_DIR override the tool and the vectors (the red log runs against a broken copy).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { fail "node not found (Node 22 is required)"; finish; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
TOOL=${TOOL_FILE:-$REPO/scripts/release/release-tool.mjs}
VEC=${VECTORS_DIR:-$REPO/tests/vectors/release}
VJ=$REPO/scripts/release/VENDORED.json
VV=$VEC/../VENDORED-release.json

echo "== 1. VENDORED.json"
if [ ! -f "$VJ" ]; then fail "scripts/release/VENDORED.json exists"; else
  ok "scripts/release/VENDORED.json exists"
  J=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j).sort().join(","),j.specRelease,j.sha256,j.source)' "$VJ" 2>&1)
  expect_eq "VENDORED.json has exactly source, specRelease and sha256" "sha256,source,specRelease" "$(printf '%s' "$J" | awk '{print $1}')"
  expect_eq "specRelease is 0.6.1" "0.6.1" "$(printf '%s' "$J" | awk '{print $2}')"
  expect_eq "sha256 equals the digest of scripts/release/release-tool.mjs" "$(sha "$TOOL")" "$(printf '%s' "$J" | awk '{print $3}')"
  expect_eq "source names runtime spec/tools/release-tool.mjs" 1 "$(printf '%s' "$J" | grep -c 'runtime spec/tools/release-tool.mjs')"
fi
expect_eq "the vendored tool is a regular file with no CR in it" 0 "$(grep -c "$(printf '\r')" "$TOOL")"

echo "== 2. -text in .gitattributes, and a clone with core.autocrlf=true keeps the digest"
for p in 'scripts/release/release-tool.mjs -text' 'scripts/release/VENDORED.json -text' 'tests/vectors/** -text'; do
  expect_eq ".gitattributes has '$p'" 1 "$(grep -cxF "$p" "$REPO/.gitattributes")"
done
if command -v git >/dev/null 2>&1; then
  S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
  mk() { # mk <dir> <with attributes: 1|0>
    mkdir -p "$1/src/scripts/release" "$1/src/tests/vectors/release"
    cp "$TOOL" "$1/src/scripts/release/release-tool.mjs"; cp "$VJ" "$1/src/scripts/release/VENDORED.json" 2>/dev/null
    cp -R "$VEC"/. "$1/src/tests/vectors/release/"
    if [ "$2" = 1 ]; then grep -E -e '-text|^\* text' "$REPO/.gitattributes" > "$1/src/.gitattributes"; else : > "$1/src/.gitattributes"; fi
    git -C "$1/src" init -q -b main >/dev/null 2>&1 || git -C "$1/src" init -q
    git -C "$1/src" add -A >/dev/null 2>&1
    git -C "$1/src" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q -m t >/dev/null 2>&1
    git clone -q -c core.autocrlf=true "$1/src" "$1/clone" >/dev/null 2>&1
  }
  mk "$S/with" 1
  expect_eq "clone with core.autocrlf=true: the tool has the same sha256 (attributes as committed)" "$(sha "$TOOL")" "$(sha "$S/with/clone/scripts/release/release-tool.mjs" 2>/dev/null)"
  FIRSTVEC=$(cd "$VEC" && find . -type f -name 'SHA256SUMS' | sort | head -1)
  expect_eq "clone with core.autocrlf=true: SHA256SUMS of a vector is byte-identical" "$(sha "$VEC/$FIRSTVEC")" "$(sha "$S/with/clone/tests/vectors/release/$FIRSTVEC" 2>/dev/null)"
  mk "$S/without" 0
  if [ "$(sha "$TOOL")" != "$(sha "$S/without/clone/scripts/release/release-tool.mjs" 2>/dev/null)" ]; then ok "control: without the -text attribute the same clone changes the digest (so this check can fail)"
  else echo "note - control: this git leaves the file unchanged without -text (autocrlf may be ignored here); the attribute check above still holds"; fi
else
  fail "git not found: the autocrlf check cannot run"
fi

echo "== 3. the vendored vectors"
if [ -f "$VV" ]; then
  GOT=$(cd "$VEC" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do printf '%s  vectors/release/%s\n' "$(sha "$f")" "$f"; done | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)
  WANT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sha256)' "$VV")
  expect_eq "the listing digest of tests/vectors/release equals the one recorded in VENDORED-release.json" "$WANT" "$GOT"
  expect_eq "tests/vectors/release holds the recorded number of files" "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).files)' "$VV")" "$(cd "$VEC" && find . -type f | wc -l | tr -d ' ')"
else
  fail "tests/vectors/VENDORED-release.json exists"
fi

echo "== 4. every release.json case through the vendored copy, in a tree with no sibling repository"
T=$(mktemp -d); trap 'rm -rf "$S" "$T"' EXIT
mkdir -p "$T/tree/scripts/release" "$T/tree/tests/scripts" "$T/tree/tests/vectors"
cp "$TOOL" "$T/tree/scripts/release/release-tool.mjs"
cp "$REPO/tests/scripts/release-vectors.mjs" "$T/tree/tests/scripts/"
cp -R "$VEC" "$T/tree/tests/vectors/release"
( cd "$T/tree" && env -u GITHUB_SHA -u GITHUB_REF node tests/scripts/release-vectors.mjs scripts/release/release-tool.mjs tests/vectors/release ) > "$T/vectors.out" 2>&1
rc=$?
grep -E '^(FAIL|n/a)' "$T/vectors.out" | sed 's/^/   /'
tail -1 "$T/vectors.out" | sed 's/^/   /'
expect_eq "every case agrees (exit code, first stderr line, JSON reason)" 0 "$rc"
expect_eq "at least 36 cases ran or are marked for another platform" 1 "$([ "$(grep -cE '^(ok|n/a)' "$T/vectors.out")" -ge 36 ] && echo 1 || echo 0)"
expect_eq "the runner and this test name no sibling path ('../' or runtime/spec)" 0 "$(grep -cE '\.\./(runtime|glyphsift|localdata|dockit|site|control-plane)|\.\./\.\./runtime|runtime/spec' "$REPO/tests/scripts/release-vectors.mjs")"

echo "== 4b. a broken copy of the tool is caught by the same runner (the runner can fail)"
sed 's/refused: /denied: /' "$TOOL" > "$T/broken.mjs"
( cd "$T/tree" && node tests/scripts/release-vectors.mjs "$T/broken.mjs" tests/vectors/release ) > "$T/broken.out" 2>&1
expect_eq "a tool that says 'denied:' instead of 'refused:' makes the runner exit 1" 1 "$?"

echo "== 5. scripts/release-manifest.mjs and 'release-tool manifest' write the same bytes for pagetriage-release"
P=$(mktemp -d); trap 'rm -rf "$S" "$T" "$P"' EXIT
mkdir -p "$P/repo/scripts/lib" "$P/repo/dist" "$P/art" "$P/rel"
cp "$REPO/scripts/release-manifest.mjs" "$P/repo/scripts/"; cp "$REPO/scripts/lib/confine.mjs" "$P/repo/scripts/lib/"; cp "$REPO/Cargo.toml" "$P/repo/Cargo.toml"
VERSION=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "$REPO/Cargo.toml" | head -1)
printf 'tgz stand-in\n' > "$P/art/airplanemode-pagetriage-$VERSION.tgz"
head -c 3000 /dev/zero | tr '\0' 'w' > "$P/art/pagetriage-core-$VERSION.crate"
printf 'wheel stand-in\n' > "$P/art/pagetriage-0.0.0-cp39-abi3-test.whl"
cp "$P/art"/* "$P/rel/"
( cd "$P/repo" && SOURCE_DATE_EPOCH=1700000000 node scripts/release-manifest.mjs --out dist/release-manifest.json "$P"/art/* > /dev/null 2>"$P/old.err" ); expect_eq "scripts/release-manifest.mjs wrote a manifest" 0 "$([ -f "$P/repo/dist/release-manifest.json" ] && echo 0 || echo 1)"
SOURCE_DATE_EPOCH=1700000000 node "$TOOL" manifest --dir "$P/rel" --id pagetriage-release --version "$VERSION" --licence 'MIT OR Apache-2.0' --publisher release > "$P/new.out" 2>"$P/new.err"
expect_eq "release-tool manifest wrote a manifest" 0 "$([ -f "$P/rel/release-manifest.json" ] && echo 0 || echo 1)"
if cmp -s "$P/repo/dist/release-manifest.json" "$P/rel/release-manifest.json"; then ok "the two manifests are byte-identical"; else fail "the two manifests are byte-identical"; diff "$P/repo/dist/release-manifest.json" "$P/rel/release-manifest.json" | head -10 | sed 's/^/   /'; fi
finish
