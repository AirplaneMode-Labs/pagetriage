#!/usr/bin/env bash
# docs/RELEASING.md is the owner's checklist, so the commands in it are tested, not trusted (FR2: BUG-T3-S7-14, S1-137a).
#  1. the documented key.pub -> base64 command, run on a synthetic cp-sign-format key.pub that holds the TEST 1 public key,
#     prints the publicKey of tests/vectors/release/keys/test-key.json; a key.pub with a wrong-length key makes it exit 1;
#  2. the section "If a publish step fails" exists and carries each recovery step with a "Why only you" reason.
# No network, no sibling repository. The synthetic key.pub holds the published RFC 8032 TEST 1 public key, which is public data.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { fail "node not found"; finish; exit 1; }
DOC=${RELEASING_DOC:-$REPO/docs/RELEASING.md}
VEC=$REPO/tests/vectors/release/keys/test-key.json
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
[ -f "$DOC" ] || { fail "docs/RELEASING.md exists"; finish; exit 1; }

# ---- 1. the base64 command
CMD=$(grep -E "^node -e '.*' <KEYDIR>/key\.pub$" "$DOC" | head -1)
expect_eq "RELEASING.md carries exactly one key.pub to base64 command (a line 'node -e ... <KEYDIR>/key.pub')" 1 "$(grep -cE "^node -e '.*' <KEYDIR>/key\.pub$" "$DOC")"
WANT=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.keys[0].publicKey)' "$VEC")
HEX=$(node -e 'process.stdout.write(Buffer.from(process.argv[1],"base64").toString("hex"))' "$WANT")
expect_eq "the TEST 1 public key of the vector is the 32 bytes d75a9801...07511a" "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" "$HEX"
mkdir -p "$S/keys"
printf '# cp-sign public key (synthetic: the published RFC 8032 TEST 1 public key)\ned25519-public %s\n' "$HEX" > "$S/keys/key.pub"
RUN=${CMD//<KEYDIR>/$S/keys}
GOT=$(bash -c "$RUN" 2>"$S/err.txt"); RC=$?
expect_eq "the documented command exits 0 on a synthetic key.pub" 0 "$RC"
expect_eq "the documented command prints the vector's publicKey (canonical padded base64)" "$WANT" "$GOT"
printf 'ed25519-public %s\r\n' "$HEX" > "$S/keys/key-crlf.pub"
expect_eq "the documented command also reads a key.pub with CRLF line endings" "$WANT" "$(bash -c "${CMD//<KEYDIR>\/key.pub/$S/keys/key-crlf.pub}" 2>/dev/null)"
printf '# short\ned25519-public %s\n' "${HEX:0:62}" > "$S/keys/short.pub"
bash -c "${CMD//<KEYDIR>\/key.pub/$S/keys/short.pub}" >"$S/short.out" 2>"$S/short.err"; SRC=$?
expect_eq "a key.pub holding 31 bytes makes the command exit 1 and print nothing on stdout" "1 0" "$SRC $(wc -c < "$S/short.out" | tr -d ' ')"
expect_eq "a key.pub with no ed25519-public line makes the command exit 1" 1 "$(printf '# nothing\n' > "$S/keys/none.pub"; bash -c "${CMD//<KEYDIR>\/key.pub/$S/keys/none.pub}" >/dev/null 2>&1; echo $?)"
expect_eq "step 4 (Commit the public key) points at the command" 1 "$(awk '/^### 4\. /{f=1; next} /^### 5\. /{f=0} f' "$DOC" | grep -c 'key\.pub')"

# ---- 2. recovery steps
SEC=$(awk '/^### If a publish step fails/{f=1; next} f && /^##/{exit} f' "$DOC")
expect_eq "RELEASING.md has the section 'If a publish step fails'" 1 "$(grep -cE '^### If a publish step fails$' "$DOC")"
need() { expect_eq "recovery section: $1" 1 "$(printf '%s\n' "$SEC" | grep -cF -- "$2")"; }
need "cargo yank --version <v> for each crate already published" 'cargo yank --version'
need "names both crates" 'pagetriage-core'
need "npm deprecate for an npm version already published" 'npm deprecate'
need "npm unpublish only within 72 hours" 'npm unpublish'
need "the 72 hours limit is stated" '72 hours'
need "revoke NPM_TOKEN" 'NPM_TOKEN'
need "revoke CARGO_REGISTRY_TOKEN" 'CARGO_REGISTRY_TOKEN'
need "disarm with gh variable set RELEASE_PUBLISH_ARMED --env release --body false" 'gh variable set RELEASE_PUBLISH_ARMED --env release --body false'
need "never re-publish the same version, bump instead" 'never re-publish'
need "bump the version" 'bump'
need "record the run id" 'run id'
expect_eq "recovery section: every step gives a 'Why only you' reason (at least 6)" 1 "$([ "$(printf '%s\n' "$SEC" | grep -c 'Why only you')" -ge 6 ] && echo 1 || echo 0)"
expect_eq "recovery section: it sits after step 17 and before 'Settings worth turning on'" yes "$(awk '/^### 17\. /{a=NR} /^### If a publish step fails/{b=NR} /^## Settings worth turning on/{c=NR} END{print (a&&b&&c&&a<b&&b<c)?"yes":"no"}' "$DOC")"
finish
