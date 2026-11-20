#!/usr/bin/env bash
# The checks .github/workflows/publish.yml runs before it publishes anything, and that scripts/release/publish-dry-run.sh shares
# (Sprint 7, D2-03; TD-105, TD-121, TD-123; security conditions S1-126 and S1-129). Every check fails closed: any doubt is exit 1 with
# one line on stderr. tests/scripts/publish-guard.sh proves each refusal with stand-ins for `gh` and `curl`; nobody runs the workflow
# before the owner does.
#
#   publish-guard.sh armed                         lock 3 (TD-125): ARMED, which the workflow takes from the step env `ARMED: ${{ vars.RELEASE_PUBLISH_ARMED }}`
#                                                  (RELEASE_PUBLISH_ARMED is a variable of the `release` environment), reads exactly 'true'. It is a step and
#                                                  never a job-level `if`: a job-level `if` cannot read an environment variable
#   publish-guard.sh version                       print the workspace version from Cargo.toml (plain SemVer, no build metadata)
#   publish-guard.sh py-version <version>          print the PEP 440 form that wheel and sdist names carry (1.0.0-rc.1 -> 1.0.0rc1)
#   publish-guard.sh dist-tag <version>            print the npm dist-tag: alpha, beta or rc, or latest for a version with no pre-release
#                                                  part (any other pre-release identifier is refused: it must not land on 'latest' by accident)
#   publish-guard.sh key-id                        lock 6 (S1-129): RELEASE_KEY_ID (64 lower-case hex, a variable of the release environment)
#                                                  equals the single key in docs/release-keys.json at the commit being published
#   publish-guard.sh tag-binding                   GUARD_REPO, GUARD_VERSION, GUARD_SHA: tag v<version> peels (annotated tags followed) to GUARD_SHA
#   publish-guard.sh manifest-binding <manifest>   GUARD_VERSION: the signed manifest says pagetriage-release, this version, the release
#                                                  publisher, no expiresAt (TD-121) and carries at least one signature
#   publish-guard.sh registry-absent               GUARD_VERSION: npm, PyPI and crates.io (core and cli) each answer 404 for this version
#   publish-guard.sh exact-set <dir> <outdir>      GUARD_VERSION: <dir> holds exactly the manifest, SHA256SUMS, the tarball, the sdist, the two
#                                                  crates and one wheel each for manylinux x86_64, macOS arm64 and win_amd64, nothing else
#                                                  (regular files only); writes the exact lists npm.txt, pypi.txt, crates.txt and all.txt to <outdir>
#   publish-guard.sh crate-digests <dir> <pkgdir>  GUARD_VERSION: the re-packaged crates in <pkgdir> (target/package) have the sha256 the
#                                                  verified manifest in <dir> lists (S1-126, TD-123); run before `cargo publish`
#   publish-guard.sh index-check <dir>             GUARD_VERSION: after `cargo publish`, the crates.io sparse index (https://index.crates.io/...) lists this version
#                                                  of pagetriage-core and pagetriage-cli with a cksum equal to the sha256 the verified manifest in <dir> lists, and
#                                                  neither is yanked (S1-131). An entry that is not there yet is retried (GUARD_INDEX_WAIT_S, default 600 seconds in
#                                                  all, every GUARD_INDEX_GAP_S, default 15); a different cksum fails at once, loudly
# The workflow passes ARMED, GUARD_* and RELEASE_KEY_ID in its step env; this script reads no runner variable and no secret and never publishes.
# GUARD_ROOT (default: the repository root) is where Cargo.toml and docs/release-keys.json are read; the tests use scratch roots.
set -euo pipefail
ROOT=${GUARD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT"

die() { echo "publish-guard: $*" >&2; exit 1; }
REPO_NAME=AirplaneMode-Labs/pagetriage
MANIFEST_ID=pagetriage-release
RELEASE_PUBLISHER='Airplane Mode Labs'
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
check_semver() { [[ "${1:-}" =~ $SEMVER ]] || die "'${1:-}' is not a plain semantic version (build metadata is not allowed)"; }
need_version() { check_semver "${GUARD_VERSION:-}"; }
to_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
pyver() { # 2.3.4 -> 2.3.4, 2.3.4-alpha.1 -> 2.3.4a1, -beta.N -> bN, -rc.N -> rcN; anything else is refused
  local v=$1 re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$'
  [[ "$v" =~ $re ]] || die "version '$v' has no PEP 440 form here (only X.Y.Z or X.Y.Z-(alpha|beta|rc).N)"
  case "$v" in
    *-alpha.*) printf '%sa%s\n' "${v%%-*}" "${v##*.}" ;;
    *-beta.*) printf '%sb%s\n' "${v%%-*}" "${v##*.}" ;;
    *-rc.*) printf '%src%s\n' "${v%%-*}" "${v##*.}" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

cmd_armed() {
  [ "${ARMED:-}" = "true" ] || die "the release is not armed: the 'release' environment variable RELEASE_PUBLISH_ARMED must read exactly 'true' (docs/RELEASING.md, step 15: arm just before you approve the waiting job, and disarm afterwards)"
  echo "ok: the release is armed (RELEASE_PUBLISH_ARMED reads true)"
}

cmd_version() {
  local v
  v=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
  check_semver "$v"
  printf '%s\n' "$v"
}

cmd_dist_tag() {
  local v=${1:-} pre first
  check_semver "$v"
  case "$v" in
    *-*)
      pre=${v#*-}; first=${pre%%.*}
      case "$first" in alpha|beta|rc) printf '%s\n' "$first" ;; *) die "pre-release identifier '$first' is not alpha, beta or rc: refusing to pick a dist-tag" ;; esac ;;
    *) printf 'latest\n' ;;
  esac
}

cmd_key_id() {
  local id=${RELEASE_KEY_ID:-}
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] || die "RELEASE_KEY_ID is unset or is not 64 lower-case hex characters"
  node -e '
    const fs = require("fs");
    let j;
    try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { console.error("publish-guard: docs/release-keys.json is missing or is not JSON"); process.exit(1); }
    if (!j || !Array.isArray(j.keys) || j.keys.length !== 1) { console.error("publish-guard: docs/release-keys.json must hold exactly one key"); process.exit(1); }
    if (typeof j.keys[0].keyId !== "string" || j.keys[0].keyId !== process.argv[2]) { console.error("publish-guard: RELEASE_KEY_ID is not the key committed in docs/release-keys.json"); process.exit(1); }
  ' "$(to_native docs/release-keys.json)" "$id"
}

cmd_tag_binding() {
  need_version
  [ "${GUARD_REPO:-}" = "$REPO_NAME" ] || die "GUARD_REPO is not $REPO_NAME"
  [[ "${GUARD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "GUARD_SHA is unset or is not a 40-character commit id"
  local ref type sha i
  ref=$(gh api "repos/$GUARD_REPO/git/ref/tags/v$GUARD_VERSION" --jq '.object.type + " " + .object.sha') || die "tag v$GUARD_VERSION does not exist (or could not be read)"
  for i in 1 2 3 4 5; do
    type=${ref%% *}; sha=${ref##* }
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected answer for tag v$GUARD_VERSION"
    case "$type" in
      commit) [ "$sha" = "$GUARD_SHA" ] || die "tag v$GUARD_VERSION resolves to $sha, not to the commit being published ($GUARD_SHA)"; echo "ok: tag v$GUARD_VERSION resolves to $GUARD_SHA"; return 0 ;;
      tag) ref=$(gh api "repos/$GUARD_REPO/git/tags/$sha" --jq '.object.type + " " + .object.sha') || die "annotated tag $sha could not be read" ;;
      *) die "tag v$GUARD_VERSION points at a $type, not a commit" ;;
    esac
  done
  die "tag v$GUARD_VERSION is nested too deeply"
}

cmd_manifest_binding() {
  need_version
  [ -f "${1:-}" ] || die "no manifest file: ${1:-}"
  node -e '
    const fs = require("fs");
    const fail = (m) => { console.error("publish-guard: " + m); process.exit(1); };
    let m;
    try { m = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { fail("the manifest is not JSON"); }
    if (!m || typeof m !== "object") fail("the manifest is not an object");
    if (m.id !== process.argv[3]) fail("the manifest id is " + JSON.stringify(m.id) + ", not " + process.argv[3]);
    if (m.version !== process.argv[2]) fail("the manifest version is " + JSON.stringify(m.version) + ", not " + process.argv[2]);
    if (m.publisher !== process.argv[4]) fail("the manifest publisher is not the release publisher");
    if ("expiresAt" in m) fail("a release manifest carries no expiresAt (TD-121)");
    if (!Array.isArray(m.signatures) || m.signatures.length < 1) fail("the manifest carries no signature");
    console.log("ok: the manifest says " + m.id + " " + m.version + ", the release publisher, no expiry, " + m.signatures.length + " signature(s)");
  ' "$(to_native "$1")" "$GUARD_VERSION" "$MANIFEST_ID" "$RELEASE_PUBLISHER"
}

lookup_404() { # <label> <url>: only an HTTP 404 means "this version is not on that registry"; anything else, a failed request included, is a refusal
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --proto '=https' --tlsv1.2 --max-time 30 -A 'airplanemode-release-guard' "$2") || die "$1: the lookup failed, so absence cannot be shown ($2)"
  [ "$code" = 404 ] || die "$1: expected 404 for this version, got $code ($2)"
  echo "ok: $1 answers 404 for $GUARD_VERSION"
}
cmd_registry_absent() {
  need_version
  local py; py=$(pyver "$GUARD_VERSION")
  lookup_404 "npm @airplanemode/pagetriage" "https://registry.npmjs.org/@airplanemode%2Fpagetriage/$GUARD_VERSION"
  lookup_404 "PyPI pagetriage" "https://pypi.org/pypi/pagetriage/$py/json"
  lookup_404 "crates.io pagetriage-core" "https://crates.io/api/v1/crates/pagetriage-core/$GUARD_VERSION"
  lookup_404 "crates.io pagetriage-cli" "https://crates.io/api/v1/crates/pagetriage-cli/$GUARD_VERSION"
}

cmd_exact_set() {
  need_version
  local dir=${1:-} out=${2:-} v=$GUARD_VERSION py f n lin=0 mac=0 win=0
  py=$(pyver "$v")
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "$dir is not a real directory"
  [ -n "$out" ] || die "no output directory"
  mkdir -p "$out"
  local want_npm="airplanemode-pagetriage-$v.tgz" want_sdist="pagetriage-$py.tar.gz" want_core="pagetriage-core-$v.crate" want_cli="pagetriage-cli-$v.crate"
  : > "$out/npm.txt"; : > "$out/pypi.txt"; : > "$out/crates.txt"; : > "$out/all.txt"
  local seen_manifest=0 seen_sums=0 seen_npm=0 seen_sdist=0 seen_core=0 seen_cli=0
  ls -A "$dir" | LC_ALL=C sort > "$out/.names"
  while IFS= read -r n; do
    f=$dir/$n
    [ -f "$f" ] && [ ! -L "$f" ] || die "$n is not a regular file"
    case "$n" in
      release-manifest.json) seen_manifest=1; continue ;;
      SHA256SUMS) seen_sums=1; continue ;;
      "$want_npm") seen_npm=1; echo "$n" >> "$out/npm.txt" ;;
      "$want_sdist") seen_sdist=1; echo "$n" >> "$out/pypi.txt" ;;
      "$want_core") seen_core=1; echo "$n" >> "$out/crates.txt" ;;
      "$want_cli") seen_cli=1; echo "$n" >> "$out/crates.txt" ;;
      "pagetriage-$py-cp39-abi3-"manylinux*_x86_64*.whl) lin=$((lin+1)); echo "$n" >> "$out/pypi.txt" ;;
      "pagetriage-$py-cp39-abi3-macosx_"*_arm64.whl) mac=$((mac+1)); echo "$n" >> "$out/pypi.txt" ;;
      "pagetriage-$py-cp39-abi3-win_amd64.whl") win=$((win+1)); echo "$n" >> "$out/pypi.txt" ;;
      *) die "unexpected file in the verified set: $n" ;;
    esac
    echo "$n" >> "$out/all.txt"
  done < "$out/.names"
  rm -f "$out/.names"
  [ "$seen_manifest" = 1 ] && [ "$seen_sums" = 1 ] || die "release-manifest.json or SHA256SUMS is missing"
  [ "$seen_npm" = 1 ] && [ "$seen_sdist" = 1 ] && [ "$seen_core" = 1 ] && [ "$seen_cli" = 1 ] || die "the tarball, the sdist or a crate is missing"
  [ "$lin" = 1 ] && [ "$mac" = 1 ] && [ "$win" = 1 ] || die "expected exactly one wheel each for manylinux x86_64, macOS arm64 and win_amd64 (got $lin, $mac, $win)"
  echo "ok: the verified set is exactly the expected $(wc -l < "$out/all.txt" | tr -d ' ') artefacts, the manifest and SHA256SUMS"
}

cmd_crate_digests() {
  need_version
  local dir=${1:-} pkg=${2:-}
  [ -f "$dir/release-manifest.json" ] || die "no release-manifest.json in $dir"
  [ -d "$pkg" ] || die "$pkg is not a directory"
  node -e '
    const fs = require("fs"), crypto = require("crypto"), path = require("path");
    const fail = (m) => { console.error("publish-guard: " + m); process.exit(1); };
    const [dir, pkg, v] = process.argv.slice(1);
    let m;
    try { m = JSON.parse(fs.readFileSync(path.join(dir, "release-manifest.json"), "utf8")); } catch (e) { fail("the verified manifest is not JSON"); }
    for (const name of ["pagetriage-core-" + v + ".crate", "pagetriage-cli-" + v + ".crate"]) {
      const e = (m.entries || []).find((x) => x.id === name);
      if (!e) fail(name + " is not in the verified manifest");
      let bytes;
      try { bytes = fs.readFileSync(path.join(pkg, name)); } catch (err) { fail(name + " was not re-packaged in " + pkg); }
      const sha = crypto.createHash("sha256").update(bytes).digest("hex");
      if (sha !== e.sha256) fail(name + ": the re-packaged crate has sha256 " + sha + ", the verified manifest says " + e.sha256);
      console.log("ok: " + name + " re-packaged to the verified digest");
    }
  ' "$(to_native "$dir")" "$(to_native "$pkg")" "$GUARD_VERSION"
}

# index_path <crate>: the path of a crate in the crates.io sparse index (crate names here are lower-case ASCII, at least four characters)
index_path() { local n=$1; printf '%s/%s/%s' "${n:0:2}" "${n:2:2}" "$n"; }

cmd_index_check() {
  need_version
  local dir=${1:-} wait=${GUARD_INDEX_WAIT_S:-600} gap=${GUARD_INDEX_GAP_S:-15} crate want code rc tmp start
  [[ "$wait" =~ ^[0-9]{1,4}$ ]] || die "GUARD_INDEX_WAIT_S is not a whole number of seconds"
  [[ "$gap" =~ ^[0-9]{1,3}$ ]] || die "GUARD_INDEX_GAP_S is not a whole number of seconds"
  [ -f "$dir/release-manifest.json" ] || die "no release-manifest.json in $dir"
  tmp=$(mktemp "${TMPDIR:-/tmp}/publish-guard-index.XXXXXX")
  start=$SECONDS
  for crate in pagetriage-core pagetriage-cli; do
    want=$(node -e '
      const fs = require("fs");
      let m;
      try { m = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { console.error("publish-guard: the verified manifest is not JSON"); process.exit(1); }
      const e = (m.entries || []).find((x) => x.id === process.argv[2]);
      if (!e || typeof e.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(e.sha256)) { console.error("publish-guard: " + process.argv[2] + " has no sha256 in the verified manifest"); process.exit(1); }
      console.log(e.sha256);
    ' "$(to_native "$dir/release-manifest.json")" "$crate-$GUARD_VERSION.crate") || { rm -f "$tmp"; exit 1; }
    while :; do
      code=$(curl -sS -o "$tmp" -w '%{http_code}' --proto '=https' --tlsv1.2 --max-time 30 -A 'airplanemode-release-guard' "https://index.crates.io/$(index_path "$crate")") || code=FAIL
      if [ "$code" = 200 ]; then
        rc=0
        # exit 0: the entry is there with the signed cksum; 3: the index does not list this version yet (retry); 1: anything else, and loud
        node -e '
          const fs = require("fs");
          const [file, crate, v, want] = process.argv.slice(1);
          const fail = (m) => { console.error("publish-guard: CRATES.IO HOLDS DIFFERENT BYTES THAN THE OWNER SIGNED, OR AN UNEXPECTED ENTRY: " + m); process.exit(1); };
          const hits = [];
          for (const line of fs.readFileSync(file, "utf8").split("\n")) {
            if (line.trim() === "") continue;
            let j;
            try { j = JSON.parse(line); } catch (e) { fail("a line of the " + crate + " index entry is not JSON"); }
            if (j && j.name === crate && j.vers === v) hits.push(j);
          }
          if (hits.length === 0) process.exit(3);
          if (hits.length > 1) fail(crate + " " + v + " is listed " + hits.length + " times");
          const h = hits[0];
          if (h.yanked === true) fail(crate + " " + v + " is yanked");
          if (typeof h.cksum !== "string" || h.cksum !== want) fail(crate + " " + v + ": the index cksum is " + JSON.stringify(h.cksum) + ", the verified manifest says " + want);
          console.log("ok: crates.io lists " + crate + " " + v + " with the signed cksum " + want);
        ' "$(to_native "$tmp")" "$crate" "$GUARD_VERSION" "$want" || rc=$?
        case "$rc" in
          0) break ;;
          3) ;;
          *) rm -f "$tmp"; exit 1 ;;
        esac
      fi
      if [ $((SECONDS - start)) -ge "$wait" ]; then
        rm -f "$tmp"
        die "$crate $GUARD_VERSION did not appear in the crates.io index with a readable entry within ${wait}s (last HTTP answer: $code)"
      fi
      sleep "$gap"
    done
  done
  rm -f "$tmp"
}

sub=${1:-}
[ "$#" -ge 1 ] && shift
case "$sub" in
  armed) cmd_armed ;;
  version) cmd_version ;;
  py-version) check_semver "${1:-}"; pyver "$1" ;;
  dist-tag) cmd_dist_tag "${1:-}" ;;
  key-id) cmd_key_id ;;
  tag-binding) cmd_tag_binding ;;
  manifest-binding) cmd_manifest_binding "${1:-}" ;;
  registry-absent) cmd_registry_absent ;;
  exact-set) cmd_exact_set "${1:-}" "${2:-}" ;;
  crate-digests) cmd_crate_digests "${1:-}" "${2:-}" ;;
  index-check) cmd_index_check "${1:-}" ;;
  *) echo "usage: publish-guard.sh armed|version|py-version|dist-tag|key-id|tag-binding|manifest-binding|registry-absent|exact-set|crate-digests|index-check" >&2; exit 2 ;;
esac
