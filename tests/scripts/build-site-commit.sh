#!/usr/bin/env bash
# Tests for the commit validation in scripts/build-site.sh. The script runs in a scratch tree with a stub
# scripts/build-wasm.sh and a stub site/tools/check-samples.mjs, so the real site/pkg/build.json is never
# touched. Needs node. SCRIPTS_DIR overrides where build-site.sh comes from.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

new_scratch
trap 'rm -rf "$SCRATCH"' EXIT
cp "$SCRIPTS_DIR/build-site.sh" "$SCRATCH/scripts/"
cat > "$SCRATCH/scripts/build-wasm.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p dist/wasm-pdf/web
echo js > dist/wasm-pdf/web/pagetriage.js
echo wasm > dist/wasm-pdf/web/pagetriage_bg.wasm
STUB
mkdir -p "$SCRATCH/site/tools"
echo '' > "$SCRATCH/site/tools/check-samples.mjs"
chmod +x "$SCRATCH/scripts/build-wasm.sh"

# commit_for <sha-or-UNSET>: the commit field build.json gets for that GITHUB_SHA.
commit_for() {
  rm -f "$SCRATCH/site/pkg/build.json"
  if [ "$1" = UNSET ]; then
    env -u GITHUB_SHA bash "$SCRATCH/scripts/build-site.sh" >/dev/null 2>&1
  else
    GITHUB_SHA=$1 bash "$SCRATCH/scripts/build-site.sh" >/dev/null 2>&1
  fi
  node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).commit)' "$SCRATCH/site/pkg/build.json" 2>/dev/null
}

H40=0123456789abcdef0123456789abcdef01234567
expect_eq "unset gives local" local "$(commit_for UNSET)"
expect_eq "empty gives local" local "$(commit_for '')"
expect_eq "abc gives local" local "$(commit_for abc)"
expect_eq "injection string gives local" local "$(commit_for 'not-a-sha;rm -rf x')"
expect_eq "40 uppercase hex gives local" local "$(commit_for "$(echo "$H40" | tr a-f A-F)")"
expect_eq "39 hex gives local" local "$(commit_for "${H40:0:39}")"
expect_eq "41 hex gives local" local "$(commit_for "${H40}8")"
expect_eq "40 hex plus newline gives local" local "$(commit_for "$H40"$'\n')"
expect_eq "valid 40 lowercase hex gives the first 12" "${H40:0:12}" "$(commit_for "$H40")"
finish
