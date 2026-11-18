#!/usr/bin/env bash
# Build the demo site: the PDF-enabled WASM package into site/pkg, then check that it reproduces the
# native reports for every sample (site/tools/check-samples.mjs). Needs what scripts/build-wasm.sh
# needs, plus node.
#
#   scripts/build-site.sh
#   SITE_NOTICES_ONLY=1 SITE_OUT=<dir> scripts/build-site.sh   write only the licence and notice files into <dir>
#                                                              (tests/scripts/build-site-notices.sh uses this)
#   python3 -m http.server 8000 --directory site     # then open http://localhost:8000
set -euo pipefail
cd "$(dirname "$0")/.."

# Licence and notice files served next to the page (the compiled crates are redistributed in pkg/). The
# .txt names make GitHub Pages serve them as plain text instead of a download. NOTICE.txt is the repository
# NOTICE plus one block per crate in the WASM build whose cargo metadata licence is exactly "MIT" (the MIT
# notice must travel with every copy, and the WASM bundle is a copy); the list comes from cargo.
write_notices() {
  local out=$1
  mkdir -p "$out"
  node scripts/gen-site-notice.mjs "$out/NOTICE.txt"
  cp LICENSE-MIT "$out/LICENSE-MIT.txt"
  cp LICENSE-APACHE "$out/LICENSE-APACHE.txt"
}
if [ "${SITE_NOTICES_ONLY:-}" = 1 ]; then write_notices "${SITE_OUT:-site}"; exit 0; fi

PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf scripts/build-wasm.sh
# An id for this build's package, so the page can keep one build's files apart from another's in the cache,
# and the commit and source it was built from for the build label. The label is "Built from main at <sha12>" when
# source is ci and "Local build <sha12>[-dirty]" when it is local.
#   ci:    GITHUB_SHA is exactly 40 lowercase hex characters; the commit is its first 12.
#   local: the commit is the first 12 characters of git HEAD of this checkout, with "-dirty" appended when the
#          working tree differs from HEAD (changed or untracked files that are not ignored; build outputs are
#          ignored). Without a git checkout, or if git answers anything else, it is "local".
# Anything else (unset, short, uppercase, garbage) never reaches the page. The tree state is read before anything is
# written into site/ (the WASM build above only writes to the ignored dist/ and target/), so it describes the sources.
COMMIT=local
SOURCE=local
if [[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
  COMMIT=${GITHUB_SHA:0:12}
  SOURCE=ci
elif [ -e .git ] && command -v git >/dev/null 2>&1; then
  HEAD40=$(git rev-parse HEAD 2>/dev/null || true)
  if [[ "$HEAD40" =~ ^[0-9a-f]{40}$ ]]; then
    COMMIT=${HEAD40:0:12}
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT=$COMMIT-dirty; fi
  fi
fi
rm -rf site/pkg
mkdir -p site/pkg
cp dist/wasm-pdf/web/pagetriage.js dist/wasm-pdf/web/pagetriage_bg.wasm site/pkg/
BUILD_COMMIT=$COMMIT BUILD_SOURCE=$SOURCE node -e 'const c=require("crypto"),f=require("fs");const h=c.createHash("sha256");for(const n of ["pagetriage.js","pagetriage_bg.wasm"])h.update(f.readFileSync("site/pkg/"+n));f.writeFileSync("site/pkg/build.json",JSON.stringify({id:h.digest("hex").slice(0,16),commit:process.env.BUILD_COMMIT,source:process.env.BUILD_SOURCE})+"\n")'
write_notices site
node site/tools/check-samples.mjs
echo "site ready in site/ (gzipped wasm: $(gzip -9 -c site/pkg/pagetriage_bg.wasm | wc -c | tr -d ' ') bytes)"
