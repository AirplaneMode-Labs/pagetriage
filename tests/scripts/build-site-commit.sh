#!/usr/bin/env bash
# Tests for the build id in scripts/build-site.sh: the commit and source fields of site/pkg/build.json. The script
# runs in a scratch tree with a stub scripts/build-wasm.sh and a stub site/tools/check-samples.mjs, so the real
# site/pkg/build.json is never touched. Needs node and git. SCRIPTS_DIR overrides where build-site.sh comes from.
#
# The page shows "Built from main at <sha12>" when source is ci (GITHUB_SHA is exactly 40 lowercase hex) and
# "Local build <sha12>[-dirty]" otherwise, where the sha is git HEAD of the tree being built and -dirty means it
# has uncommitted changes or untracked files that are not ignored. Without a git checkout the commit is "local".
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
# field_for <field> <sha-or-UNSET>: that field of the build.json the script writes for that GITHUB_SHA.
field_for() {
  rm -f "$SCRATCH/site/pkg/build.json"
  if [ "$2" = UNSET ]; then
    env -u GITHUB_SHA bash "$SCRATCH/scripts/build-site.sh" >/dev/null 2>&1
  else
    GITHUB_SHA=$2 bash "$SCRATCH/scripts/build-site.sh" >/dev/null 2>&1
  fi
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j[process.argv[2]]))' "$SCRATCH/site/pkg/build.json" "$1" 2>/dev/null
}
commit_for() { field_for commit "$1"; }

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

# source: ci only for a valid GITHUB_SHA; everything else is local
expect_eq "valid GITHUB_SHA: source is ci" ci "$(field_for source "$H40")"
expect_eq "unset, no git checkout: source is local" local "$(field_for source UNSET)"
expect_eq "garbage GITHUB_SHA: source is local" local "$(field_for source 'not-a-sha;rm -rf x')"
expect_eq "build.json keys are id, commit, source" "commit,id,source" "$(node -e 'process.stdout.write(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).sort().join(","))' "$SCRATCH/site/pkg/build.json")"

# a git checkout: the local build id is HEAD of the tree, and -dirty when it differs from HEAD
if ! command -v git >/dev/null 2>&1; then fail "git not found: the local build id cannot be tested"; finish; exit 1; fi
printf 'dist/\nsite/pkg/\nsite/NOTICE.txt\n' > "$SCRATCH/.gitignore"
echo one > "$SCRATCH/tracked.txt"
G() { git -C "$SCRATCH" -c user.name=scratch -c user.email=scratch@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
G init -q && G add .gitignore tracked.txt scripts site crates && G commit -q -m scratch || fail "scratch git repository could not be created"
HEAD40=$(G rev-parse HEAD)
expect_eq "clean git tree, GITHUB_SHA unset: commit is HEAD's first 12" "${HEAD40:0:12}" "$(commit_for UNSET)"
expect_eq "clean git tree: source is local" local "$(field_for source UNSET)"
expect_eq "garbage GITHUB_SHA in a git tree: git's HEAD is used, never the garbage" "${HEAD40:0:12}" "$(commit_for 'not-a-sha;rm -rf x')"
echo two >> "$SCRATCH/tracked.txt"
expect_eq "modified tracked file: -dirty" "${HEAD40:0:12}-dirty" "$(commit_for UNSET)"
G checkout -q -- tracked.txt
echo new > "$SCRATCH/untracked.txt"
expect_eq "untracked file that is not ignored: -dirty" "${HEAD40:0:12}-dirty" "$(commit_for UNSET)"
rm -f "$SCRATCH/untracked.txt"
expect_eq "back to clean: no -dirty (build outputs are ignored)" "${HEAD40:0:12}" "$(commit_for UNSET)"
echo two >> "$SCRATCH/tracked.txt"
expect_eq "valid GITHUB_SHA wins over git, with no -dirty" "${H40:0:12}" "$(commit_for "$H40")"
expect_eq "valid GITHUB_SHA: source is ci even in a dirty tree" ci "$(field_for source "$H40")"
finish
