#!/usr/bin/env bash
# Build the demo site: the PDF-enabled WASM package into site/pkg, then check that it reproduces the
# native reports for every sample (site/tools/check-samples.mjs). Needs what scripts/build-wasm.sh
# needs, plus node.
#
#   scripts/build-site.sh
#   python3 -m http.server 8000 --directory site     # then open http://localhost:8000
set -euo pipefail
cd "$(dirname "$0")/.."

PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf scripts/build-wasm.sh
rm -rf site/pkg
mkdir -p site/pkg
cp dist/wasm-pdf/web/pagetriage.js dist/wasm-pdf/web/pagetriage_bg.wasm site/pkg/
# An id for this build's package, so the page can keep one build's files apart from another's in the cache,
# and the commit it was built from for the status line. The commit is the first 12 characters of
# GITHUB_SHA only when that is exactly 40 lowercase hex characters; anything else (unset, short,
# uppercase, garbage) gives "local", so nothing unvalidated reaches the page.
COMMIT=local
if [[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then COMMIT=${GITHUB_SHA:0:12}; fi
BUILD_COMMIT=$COMMIT node -e 'const c=require("crypto"),f=require("fs");const h=c.createHash("sha256");for(const n of ["pagetriage.js","pagetriage_bg.wasm"])h.update(f.readFileSync("site/pkg/"+n));f.writeFileSync("site/pkg/build.json",JSON.stringify({id:h.digest("hex").slice(0,16),commit:process.env.BUILD_COMMIT})+"\n")'
node site/tools/check-samples.mjs
echo "site ready in site/ (gzipped wasm: $(gzip -9 -c site/pkg/pagetriage_bg.wasm | wc -c | tr -d ' ') bytes)"
