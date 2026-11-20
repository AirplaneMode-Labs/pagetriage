#!/usr/bin/env bash
# Tests for scripts/release/publish-guard.sh, the checks publish.yml runs before it publishes (Sprint 7, D2-03; TD-105, TD-121, TD-123;
# S1-126, S1-129). Every check must fail closed, so each one is shown to REFUSE its bad input, not only to accept a good one. `gh` and
# `curl` are stand-ins first on PATH (no network, no token); the repository root is a scratch root with its own Cargo.toml and
# docs/release-keys.json. GUARD_SCRIPT overrides the script under test (the red log points it at a missing file).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { fail "node not found"; finish; exit 1; }
GUARD=${GUARD_SCRIPT:-$REPO/scripts/release/publish-guard.sh}
[ -f "$GUARD" ] || { fail "scripts/release/publish-guard.sh exists"; finish; exit 1; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
# Symlinks: on Windows (Git Bash) `ln -s` silently COPIES an existing target, and fails on a missing one, unless MSYS=winsymlinks:nativestrict
# (the same rule as tests/scripts/release-manifest.sh; run 44651022212: both link refusals below "passed" the guard on Windows because no
# link had been made). With it, `ln -s` makes a native link or fails. Every link is asserted with [ -L ], and a link that cannot be made
# FAILS the run: the refusal of a link would be unproven there.
export MSYS=winsymlinks:nativestrict
# mklink <target> <link>: ln -s, then [ -L ]; returns 1 (and records a failure) when no link was made
mklink() {
  local err; err=$(ln -s "$1" "$2" 2>&1)
  if [ -L "$2" ]; then return 0; fi
  fail "could not create a symlink: the refusal of a link is unproven on this runner (${2##*/}: $err)"
  return 1
}
STUB=$S/stub; mkdir -p "$STUB/bin"
# stand-in gh: `gh api repos/<repo>/git/ref/tags/v<ver> --jq ...` prints $STUB/gh.ref, `gh api repos/<repo>/git/tags/<sha> --jq ...` prints
# $STUB/gh.tag.<sha>; a missing file is a failed call (exit 1), like a 404
cat > "$STUB/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  repos/*/git/ref/tags/*) f=$STUB/gh.ref ;;
  repos/*/git/tags/*) f=$STUB/gh.tag.${2##*/} ;;
  *) exit 2 ;;
esac
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$f"
SH
# stand-in curl: prints the HTTP code that $STUB/curl.map gives for the URL (a line "<url> <code> [<body file>]"), logs the URL and, when
# asked to write the body (-o <file>), writes the body file or nothing; $STUB/seq.<url with every non-alphanumeric turned into _> holds
# lines "<code> [<body file>]" that are used one per request (the last one repeats), to show a retry; an unknown URL or the word FAIL is a
# failed request (exit 7)
cat > "$STUB/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
url=${!#}
echo "$url" >> "$STUB/curl.log"
key=$(printf '%s' "$url" | tr -c 'A-Za-z0-9' _)
if [ -f "$STUB/seq.$key" ]; then
  line=$(head -n 1 "$STUB/seq.$key")
  if [ "$(wc -l < "$STUB/seq.$key" | tr -d ' ')" -gt 1 ]; then tail -n +2 "$STUB/seq.$key" > "$STUB/seq.$key.n"; mv "$STUB/seq.$key.n" "$STUB/seq.$key"; fi
else
  line=$(awk -v u="$url" '$1==u{$1=""; sub(/^ /,""); print; exit}' "$STUB/curl.map" 2>/dev/null)
fi
code=${line%% *}; body=""
case "$line" in *" "*) body=${line#* } ;; esac
[ -n "$code" ] && [ "$code" != FAIL ] || exit 7
if [ -n "$out" ] && [ "$out" != /dev/null ]; then if [ -n "$body" ]; then cat "$body" > "$out"; else : > "$out"; fi; fi
printf '%s' "$code"
SH
chmod +x "$STUB/bin/gh" "$STUB/bin/curl"
export STUB

V=1.0.0-rc.1; PV=1.0.0rc1; SHA=0123456789abcdef0123456789abcdef01234567; OTHER=fedcba9876543210fedcba9876543210fedcba98
KEYID=21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9
root() { local r=$S/root-$1; rm -rf "$r"; mkdir -p "$r/docs"; printf '[workspace.package]\nversion = "%s"\n' "${2:-$V}" > "$r/Cargo.toml"; printf '{"spec":"airplanemode.release-keys/0.1","keys":[{"keyId":"%s","publicKey":"x"}]}\n' "$KEYID" > "$r/docs/release-keys.json"; echo "$r"; }
# g <args...>: run the guard with the stand-ins first on PATH and a scrubbed environment; GUARD_* and RELEASE_KEY_ID come from $ENVV
g() { env -i PATH="$STUB/bin:$PATH" HOME="$S" ${SYSTEMROOT:+SYSTEMROOT="$SYSTEMROOT"} STUB="$STUB" GUARD_ROOT="${ROOT_UNDER_TEST:-$(root default)}" ${ENVV:-} bash "$GUARD" "$@" > "$S/g.out" 2> "$S/g.err"; echo $?; }
refuses() { # refuses <name> <want exit> <args...> : the exit code is exactly the wanted one and stderr says why in one line
  local name=$1 want=$2; shift 2
  local rc; rc=$(g "$@")
  if [ "$rc" = "$want" ] && [ -s "$S/g.err" ]; then ok "$name"; else fail "$name (want exit $want with a message, got $rc: $(head -c 200 "$S/g.err" | tr '\n' ' '))"; fi
}
accepts() { local name=$1; shift; local rc; rc=$(g "$@"); if [ "$rc" = 0 ]; then ok "$name"; else fail "$name (exit $rc: $(head -c 200 "$S/g.err" | tr '\n' ' '))"; fi; }

echo "== version, py-version, dist-tag"
ROOT_UNDER_TEST=$(root v)
ENVV=""; accepts "version reads [workspace.package] of the root" version; expect_eq "version prints $V" "$V" "$(cat "$S/g.out")"
ROOT_UNDER_TEST=$(root bm "1.0.0-rc.1+build5"); refuses "a version with build metadata is refused" 1 version
ROOT_UNDER_TEST=$(root v)
for t in "1.0.0-rc.1:1.0.0rc1" "0.4.0-alpha.1:0.4.0a1" "0.3.0-beta.2:0.3.0b2" "2.3.4:2.3.4"; do
  accepts "py-version ${t%%:*}" py-version "${t%%:*}"; expect_eq "py-version ${t%%:*} prints ${t##*:}" "${t##*:}" "$(cat "$S/g.out")"
done
refuses "py-version of 2.3.4-dev.1 is refused" 1 py-version 2.3.4-dev.1
for t in "1.0.0-rc.1:rc" "0.4.0-alpha.1:alpha" "0.3.0-beta.2:beta" "2.3.4:latest"; do
  accepts "dist-tag ${t%%:*}" dist-tag "${t%%:*}"; expect_eq "dist-tag ${t%%:*} is ${t##*:}" "${t##*:}" "$(cat "$S/g.out")"
done
refuses "dist-tag of 2.3.4-dev.1 is refused (never 'latest' by accident)" 1 dist-tag 2.3.4-dev.1
refuses "dist-tag of a non-version is refused" 1 dist-tag 'v2.3.4'

echo "== lock 6: RELEASE_KEY_ID equals the single key in docs/release-keys.json"
ROOT_UNDER_TEST=$(root k)
ENVV="RELEASE_KEY_ID=$KEYID"; accepts "the matching key id passes" key-id
ENVV=""; refuses "an unset RELEASE_KEY_ID is refused" 1 key-id
ENVV="RELEASE_KEY_ID=NOTHEX"; refuses "a non-hex RELEASE_KEY_ID is refused" 1 key-id
ENVV="RELEASE_KEY_ID=${KEYID%?}0"; refuses "a different key id is refused" 1 key-id
ENVV="RELEASE_KEY_ID=$(echo "$KEYID" | tr a-f A-F)"; refuses "upper-case hex is refused" 1 key-id
printf '{"spec":"airplanemode.release-keys/0.1","keys":[]}\n' > "$ROOT_UNDER_TEST/docs/release-keys.json"
ENVV="RELEASE_KEY_ID=$KEYID"; refuses "empty docs/release-keys.json (the committed state today) is refused" 1 key-id
printf '{"spec":"airplanemode.release-keys/0.1","keys":[{"keyId":"%s","publicKey":"x"},{"keyId":"%s","publicKey":"y"}]}\n' "$KEYID" "${KEYID%?}0" > "$ROOT_UNDER_TEST/docs/release-keys.json"
refuses "two keys are refused (exactly one)" 1 key-id
rm -f "$ROOT_UNDER_TEST/docs/release-keys.json"; refuses "a missing docs/release-keys.json is refused" 1 key-id
echo '{' > "$ROOT_UNDER_TEST/docs/release-keys.json"; refuses "docs/release-keys.json that is not JSON is refused" 1 key-id
ROOT_UNDER_TEST=$(root real)

echo "== lock 3: the release is armed (an environment variable read in a step, never in a job-level if; TD-125)"
ROOT_UNDER_TEST=$(root a)
ENVV="ARMED=true"; accepts "ARMED=true passes" armed
for v in false False TRUE True 1 yes on ""; do
  ENVV="ARMED=$v"; refuses "ARMED='$v' is refused (only the exact word true arms)" 1 armed
done
ENVV=""; refuses "an unset ARMED is refused" 1 armed
ENVV="RELEASE_PUBLISH_ARMED=true"; refuses "the variable's own name in the environment does not arm (the workflow maps it to ARMED in one step env)" 1 armed
ROOT_UNDER_TEST=$(root real)

echo "== binding 1: tag v<version> peels to the commit being published"
ENVV="GUARD_REPO=AirplaneMode-Labs/pagetriage GUARD_VERSION=$V GUARD_SHA=$SHA"
rm -f "$STUB"/gh.*
printf 'commit %s\n' "$SHA" > "$STUB/gh.ref"; accepts "a lightweight tag on this commit passes" tag-binding
printf 'commit %s\n' "$OTHER" > "$STUB/gh.ref"; refuses "a tag on another commit is refused" 1 tag-binding
printf 'tag %s\n' "$OTHER" > "$STUB/gh.ref"; printf 'commit %s\n' "$SHA" > "$STUB/gh.tag.$OTHER"; accepts "an annotated tag is peeled to this commit" tag-binding
printf 'commit %s\n' "$OTHER" > "$STUB/gh.tag.$OTHER"; refuses "an annotated tag that peels to another commit is refused" 1 tag-binding
printf 'tag %s\n' "$OTHER" > "$STUB/gh.ref"; rm -f "$STUB/gh.tag.$OTHER"; refuses "an annotated tag object that cannot be read is refused" 1 tag-binding
printf 'tag %s\n' "$OTHER" > "$STUB/gh.ref"; printf 'tag %s\n' "$OTHER" > "$STUB/gh.tag.$OTHER"; refuses "a tag that points at itself (a loop) is refused" 1 tag-binding
printf 'tree %s\n' "$SHA" > "$STUB/gh.ref"; refuses "a tag on a tree is refused" 1 tag-binding
printf 'garbage\n' > "$STUB/gh.ref"; refuses "an unexpected answer is refused" 1 tag-binding
rm -f "$STUB/gh.ref"; refuses "a missing tag (gh fails) is refused" 1 tag-binding
printf 'commit %s\n' "$SHA" > "$STUB/gh.ref"
ENVV="GUARD_REPO=Someone/pagetriage GUARD_VERSION=$V GUARD_SHA=$SHA"; refuses "another repository is refused" 1 tag-binding
ENVV="GUARD_REPO=AirplaneMode-Labs/pagetriage GUARD_VERSION=$V GUARD_SHA=short"; refuses "a malformed commit id is refused" 1 tag-binding
ENVV="GUARD_REPO=AirplaneMode-Labs/pagetriage GUARD_VERSION=2.3.4+x GUARD_SHA=$SHA"; refuses "a version with build metadata is refused" 1 tag-binding
ENVV="GUARD_REPO=AirplaneMode-Labs/pagetriage GUARD_SHA=$SHA"; refuses "an unset GUARD_VERSION is refused" 1 tag-binding

echo "== binding 2: the signed manifest says pagetriage-release, this version, no expiry"
ENVV="GUARD_VERSION=$V"
mf() { printf '%s\n' "$1" > "$S/m.json"; }
GOODM='{"spec":"airplanemode.manifest/0.1","id":"pagetriage-release","version":"1.0.0-rc.1","publisher":"Airplane Mode Labs","createdAt":"2026-11-20T00:00:00Z","entries":[],"signatures":[{"alg":"ed25519"}]}'
mf "$GOODM"; accepts "a correct release manifest passes" manifest-binding "$S/m.json"
mf "${GOODM/pagetriage-release/pagetriage-rehearsal}"; refuses "a rehearsal id is refused" 1 manifest-binding "$S/m.json"
mf "${GOODM/pagetriage-release/glyphsift-release}"; refuses "another package's id is refused" 1 manifest-binding "$S/m.json"
mf "${GOODM/1.0.0-rc.1/1.0.1}"; refuses "another version is refused" 1 manifest-binding "$S/m.json"
mf "${GOODM/Airplane Mode Labs/Airplane Mode Labs REHEARSAL}"; refuses "another publisher is refused" 1 manifest-binding "$S/m.json"
mf "${GOODM/\"createdAt\"/\"expiresAt\":\"2027-01-01T00:00:00Z\",\"createdAt\"}"; refuses "an expiresAt is refused (TD-121)" 1 manifest-binding "$S/m.json"
mf "${GOODM/\{\"alg\":\"ed25519\"\}/}"; refuses "no signature is refused" 1 manifest-binding "$S/m.json"
mf 'not json'; refuses "a manifest that is not JSON is refused" 1 manifest-binding "$S/m.json"
refuses "a missing manifest file is refused" 1 manifest-binding "$S/none.json"

echo "== binding 3: no registry holds this version (only a 404 passes)"
ENVV="GUARD_VERSION=$V"
NPM="https://registry.npmjs.org/@airplanemode%2Fpagetriage/$V"; PYPI="https://pypi.org/pypi/pagetriage/$PV/json"
CORE="https://crates.io/api/v1/crates/pagetriage-core/$V"; CLI="https://crates.io/api/v1/crates/pagetriage-cli/$V"
setmap() { printf '%s %s\n%s %s\n%s %s\n%s %s\n' "$NPM" "$1" "$PYPI" "$2" "$CORE" "$3" "$CLI" "$4" > "$STUB/curl.map"; : > "$STUB/curl.log"; }
setmap 404 404 404 404; accepts "four 404s pass" registry-absent
expect_eq "PyPI is asked about the PEP 440 version 1.0.0rc1, npm and crates.io about the SemVer one" 4 "$(grep -cE "pagetriage/$PV/json|airplanemode%2Fpagetriage/$V|pagetriage-core/$V|pagetriage-cli/$V" "$STUB/curl.log" | tr -d ' ')"
setmap 200 404 404 404; refuses "npm already holding the version is refused" 1 registry-absent
setmap 404 200 404 404; refuses "PyPI already holding the version is refused" 1 registry-absent
setmap 404 404 200 404; refuses "crates.io already holding pagetriage-core is refused" 1 registry-absent
setmap 404 404 404 200; refuses "crates.io already holding pagetriage-cli is refused" 1 registry-absent
setmap 404 404 404 500; refuses "a 500 answer is refused (absence is not shown)" 1 registry-absent
setmap 404 FAIL 404 404; refuses "a failed request is refused" 1 registry-absent
setmap 301 404 404 404; refuses "a redirect is refused" 1 registry-absent
: > "$STUB/curl.map"; refuses "no answers at all are refused" 1 registry-absent

echo "== exact set: the verified directory holds exactly the expected files"
ENVV="GUARD_VERSION=$V"
mkset() { local d=$S/set-$1; rm -rf "$d"; mkdir -p "$d"
  for n in release-manifest.json SHA256SUMS "airplanemode-pagetriage-$V.tgz" "pagetriage-$PV.tar.gz" "pagetriage-core-$V.crate" "pagetriage-cli-$V.crate" \
           "pagetriage-$PV-cp39-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl" "pagetriage-$PV-cp39-abi3-macosx_11_0_arm64.whl" "pagetriage-$PV-cp39-abi3-win_amd64.whl"; do printf 'x\n' > "$d/$n"; done
  echo "$d"; }
D=$(mkset good); accepts "the expected seven artefacts plus the manifest and SHA256SUMS pass" exact-set "$D" "$S/lists-good"
expect_eq "all.txt lists seven artefacts (tarball, sdist, two crates, three wheels)" 7 "$(wc -l < "$S/lists-good/all.txt" | tr -d ' ')"
expect_eq "npm.txt lists the tarball only" "airplanemode-pagetriage-$V.tgz" "$(cat "$S/lists-good/npm.txt")"
expect_eq "pypi.txt lists the sdist and three wheels" 4 "$(wc -l < "$S/lists-good/pypi.txt" | tr -d ' ')"
expect_eq "crates.txt lists core then cli (sorted)" "pagetriage-cli-$V.crate pagetriage-core-$V.crate" "$(tr '\n' ' ' < "$S/lists-good/crates.txt" | sed 's/ $//')"
D=$(mkset extra); printf 'x\n' > "$D/notes.txt"; refuses "an extra file is refused" 1 exact-set "$D" "$S/l1"
D=$(mkset nowin); rm "$D/pagetriage-$PV-cp39-abi3-win_amd64.whl"; refuses "a missing Windows wheel is refused" 1 exact-set "$D" "$S/l2"
D=$(mkset twolin); printf 'x\n' > "$D/pagetriage-$PV-cp39-abi3-manylinux_2_28_x86_64.whl"; refuses "a second Linux wheel is refused" 1 exact-set "$D" "$S/l3"
D=$(mkset nosdist); rm "$D/pagetriage-$PV.tar.gz"; refuses "a missing sdist is refused" 1 exact-set "$D" "$S/l4"
D=$(mkset nocrate); rm "$D/pagetriage-cli-$V.crate"; refuses "a missing crate is refused" 1 exact-set "$D" "$S/l5"
D=$(mkset wrongver); mv "$D/pagetriage-core-$V.crate" "$D/pagetriage-core-1.0.1.crate"; refuses "a crate of another version is refused" 1 exact-set "$D" "$S/l6"
D=$(mkset plainwheel); mv "$D/pagetriage-$PV-cp39-abi3-win_amd64.whl" "$D/pagetriage-$V-cp39-abi3-win_amd64.whl"; refuses "a wheel named with the SemVer form (not PEP 440) is refused" 1 exact-set "$D" "$S/l7"
D=$(mkset sub); mkdir "$D/sub"; refuses "a subdirectory is refused" 1 exact-set "$D" "$S/l8"
D=$(mkset link); rm -f "$D/pagetriage-$PV-cp39-abi3-macosx_11_0_arm64.whl"
if mklink "$D/SHA256SUMS" "$D/pagetriage-$PV-cp39-abi3-macosx_11_0_arm64.whl"; then
  refuses "a symbolic link in the set is refused" 1 exact-set "$D" "$S/l9"
fi
refuses "a directory that does not exist is refused" 1 exact-set "$S/no-such-dir" "$S/l10"
LINKDIR=$S/linkdir
if mklink "$(mkset target)" "$LINKDIR"; then
  refuses "a symlinked verify directory is refused" 1 exact-set "$LINKDIR" "$S/l11"
fi

echo "== crate digests: the re-packaged crates have the digests the owner signed (S1-126)"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
D=$S/cd; PK=$S/cd-pkg; rm -rf "$D" "$PK"; mkdir -p "$D" "$PK"
printf 'core bytes\n' > "$PK/pagetriage-core-$V.crate"; printf 'cli bytes\n' > "$PK/pagetriage-cli-$V.crate"
printf '{"entries":[{"id":"pagetriage-core-%s.crate","sha256":"%s"},{"id":"pagetriage-cli-%s.crate","sha256":"%s"}]}\n' "$V" "$(sha "$PK/pagetriage-core-$V.crate")" "$V" "$(sha "$PK/pagetriage-cli-$V.crate")" > "$D/release-manifest.json"
accepts "re-packaged crates equal the signed digests" crate-digests "$D" "$PK"
printf 'core bytes, changed\n' > "$PK/pagetriage-core-$V.crate"; refuses "a re-packaged core crate with another digest is refused" 1 crate-digests "$D" "$PK"
printf 'core bytes\n' > "$PK/pagetriage-core-$V.crate"; printf 'cli bytes, changed\n' > "$PK/pagetriage-cli-$V.crate"; refuses "a re-packaged cli crate with another digest is refused" 1 crate-digests "$D" "$PK"
printf 'cli bytes\n' > "$PK/pagetriage-cli-$V.crate"; rm "$PK/pagetriage-cli-$V.crate"; refuses "a crate that was not re-packaged is refused" 1 crate-digests "$D" "$PK"
printf 'cli bytes\n' > "$PK/pagetriage-cli-$V.crate"; printf '{"entries":[]}\n' > "$D/release-manifest.json"; refuses "a crate that the manifest does not list is refused" 1 crate-digests "$D" "$PK"
echo 'not json' > "$D/release-manifest.json"; refuses "a manifest that is not JSON is refused" 1 crate-digests "$D" "$PK"

echo "== index check: after cargo publish, the crates.io sparse index holds the bytes the owner signed (S1-131)"
D=$S/ix; rm -rf "$D"; mkdir -p "$D/body"
CSUM_CORE=$(printf 'core crate bytes' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)
CSUM_CLI=$(printf 'cli crate bytes' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)
printf '{"entries":[{"id":"pagetriage-core-%s.crate","sha256":"%s"},{"id":"pagetriage-cli-%s.crate","sha256":"%s"}]}\n' "$V" "$CSUM_CORE" "$V" "$CSUM_CLI" > "$D/release-manifest.json"
IXCORE="https://index.crates.io/pa/ge/pagetriage-core"; IXCLI="https://index.crates.io/pa/ge/pagetriage-cli"
ixrow() { printf '{"name":"%s","vers":"%s","deps":[],"cksum":"%s","features":{},"yanked":%s}\n' "$1" "$2" "$3" "${4:-false}"; }
ixfile() { # ixfile <name> <crate> <lines...>
  local f=$D/body/$1; shift; : > "$f"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done; echo "$f"; }
setix() { printf '%s 200 %s\n%s 200 %s\n' "$IXCORE" "$1" "$IXCLI" "$2" > "$STUB/curl.map"; : > "$STUB/curl.log"; rm -f "$STUB"/seq.*; }
GOODCORE=$(ixfile good-core "$(ixrow pagetriage-core 0.9.0 deadbeef)" "$(ixrow pagetriage-core "$V" "$CSUM_CORE")")
GOODCLI=$(ixfile good-cli "$(ixrow pagetriage-cli "$V" "$CSUM_CLI")")
ENVV="GUARD_VERSION=$V GUARD_INDEX_WAIT_S=0 GUARD_INDEX_GAP_S=0"
setix "$GOODCORE" "$GOODCLI"; accepts "both index entries carry the signed cksum" index-check "$D"
expect_eq "the sparse-index paths for pagetriage-core and pagetriage-cli are pa/ge/<name>" 2 "$(grep -cE '^https://index.crates.io/pa/ge/pagetriage-(core|cli)$' "$STUB/curl.log" | tr -d ' ')"
BADCORE=$(ixfile bad-core "$(ixrow pagetriage-core "$V" "$(printf '%064d' 0)")")
setix "$BADCORE" "$GOODCLI"; refuses "a core cksum that differs from the signed sha256 is refused, loudly, at once" 1 index-check "$D"
expect_eq "the refusal names the cksum mismatch" 1 "$(grep -ciE 'mismatch|different' "$S/g.err" | awk '{print ($1>0)?1:0}')"
BADCLI=$(ixfile bad-cli "$(ixrow pagetriage-cli "$V" "$(printf '%064d' 0 | tr 0 f)")")
setix "$GOODCORE" "$BADCLI"; refuses "a cli cksum that differs from the signed sha256 is refused" 1 index-check "$D"
YANKED=$(ixfile yanked "$(ixrow pagetriage-core "$V" "$CSUM_CORE" true)")
setix "$YANKED" "$GOODCLI"; refuses "a yanked entry is refused" 1 index-check "$D"
TWICE=$(ixfile twice "$(ixrow pagetriage-core "$V" "$CSUM_CORE")" "$(ixrow pagetriage-core "$V" "$CSUM_CORE")")
setix "$TWICE" "$GOODCLI"; refuses "two entries for the same version are refused" 1 index-check "$D"
OLD=$(ixfile only-old "$(ixrow pagetriage-core 0.9.0 deadbeef)")
setix "$OLD" "$GOODCLI"; refuses "an index that does not list this version (after the wait) is refused" 1 index-check "$D"
GARBAGE=$(ixfile garbage "not json")
setix "$GARBAGE" "$GOODCLI"; refuses "an index line that is not JSON is refused" 1 index-check "$D"
printf '%s 500\n%s 200 %s\n' "$IXCORE" "$IXCLI" "$GOODCLI" > "$STUB/curl.map"; refuses "a 500 answer for the whole wait is refused" 1 index-check "$D"
printf '%s FAIL\n%s 200 %s\n' "$IXCORE" "$IXCLI" "$GOODCLI" > "$STUB/curl.map"; refuses "a failed request for the whole wait is refused" 1 index-check "$D"
setix "$GOODCORE" "$GOODCLI"
printf '404\n404\n200 %s\n' "$GOODCORE" > "$STUB/seq.$(printf '%s' "$IXCORE" | tr -c 'A-Za-z0-9' _)"
ENVV="GUARD_VERSION=$V GUARD_INDEX_WAIT_S=30 GUARD_INDEX_GAP_S=0"; accepts "a 404, a 404 and then the entry: the check retries and passes" index-check "$D"
expect_eq "the index of pagetriage-core was asked three times (two retries)" 3 "$(grep -cF "$IXCORE" "$STUB/curl.log" | tr -d ' ')"
ENVV="GUARD_VERSION=$V GUARD_INDEX_WAIT_S=0 GUARD_INDEX_GAP_S=0"
printf '{"entries":[{"id":"pagetriage-cli-%s.crate","sha256":"%s"}]}\n' "$V" "$CSUM_CLI" > "$S/ix-nocore.json"; mkdir -p "$S/ix-nocore"; cp "$S/ix-nocore.json" "$S/ix-nocore/release-manifest.json"
setix "$GOODCORE" "$GOODCLI"; refuses "a crate that the signed manifest does not list is refused" 1 index-check "$S/ix-nocore"
refuses "a directory without a manifest is refused" 1 index-check "$S/no-such"
ENVV="GUARD_VERSION=$V GUARD_INDEX_WAIT_S=forever GUARD_INDEX_GAP_S=0"; setix "$GOODCORE" "$GOODCLI"; refuses "a non-numeric GUARD_INDEX_WAIT_S is refused" 1 index-check "$D"
ENVV=""; refuses "an unset GUARD_VERSION is refused" 1 index-check "$D"
expect_eq "the default wait is 10 minutes (GUARD_INDEX_WAIT_S default 600)" 1 "$(grep -cE 'GUARD_INDEX_WAIT_S:-600' "$GUARD" | awk '{print ($1>=1)?1:0}')"

echo "== the guard itself"
expect_eq "an unknown subcommand is a usage error (exit 2)" 2 "$(g frobnicate)"
expect_eq "the guard reads no secret and no runner variable" 0 "$(grep -vE '^[[:space:]]*#' "$GUARD" | grep -cE 'secrets\.|GITHUB_TOKEN|GITHUB_SHA|GITHUB_REF|NPM_TOKEN|CARGO_REGISTRY_TOKEN')"
expect_eq "the guard never publishes" 0 "$(grep -vE '^[[:space:]]*#' "$GUARD" | grep -cE 'npm publish|cargo publish|twine|gh release (create|upload)')"
finish
