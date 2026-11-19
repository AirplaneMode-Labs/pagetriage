#!/usr/bin/env bash
# The CI rules of Sprint 6 (S1-079, S1-117, TD-09) checked on the committed workflow files and requirement files, without
# the network. It does not replace running the workflows; it keeps the rules from drifting. Red before .github/workflows/ci.yml
# was changed (red/D2-04-ci-policy.log), green after.
#
#  A. every `uses:` in .github/workflows/*.yml is owner/repo@<40-hex SHA> # <tag>, and the (action, SHA, tag) triple is a row of
#     the conventions table below (no new action);
#  B. S1-117, the determinism job: setup-python pins an exact python-version (x.y.z); numpy and Pillow come from the hashed
#     tools/ci/requirements-determinism.txt through `pip install --require-hashes --no-deps --only-binary=:all:` on every OS;
#     bench/requirements.txt (loose lower bounds) is no longer installed by CI; the hashed file pins both with == and
#     carries at least one hash per platform wheel;
#  C. the wheels job (TD-09, S1-079; D2-05): matrix ubuntu, windows and macos; contents: read at job level and no id-token or
#     attestations anywhere; no cache action and no Swatinem/rust-cache in it; tools from tools/ci/requirements.txt with
#     --require-hashes --no-deps --only-binary=:all: and an exact python-version; every cargo and maturin build line says
#     --locked; manylinux_2_17 through zig on ubuntu; an sdist; an install with --no-index and a real call; SHA256SUMS written
#     and printed; one upload-artifact step with retention-days: 14 and if-no-files-found: error; no publish, release, registry
#     or Pages step and no secret;
#  D. ci.yml: no pull_request_target, no `secrets.`, no pages: write or id-token: write; every checkout has
#     persist-credentials: false; every job sets its own permissions.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
WF=${WF:-$REPO/.github/workflows}
TOOLS=${CI_TOOLS_DIR:-$REPO/tools/ci}
CI=$WF/ci.yml
[ -f "$CI" ] || { echo "error: $CI not found" >&2; exit 1; }

# job_text <file> <job>: the lines of one job under `jobs:` (jobs are the two-space-indented keys).
job_text() { awk -v job="$2" '/^jobs:/{inj=1; next} inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/{cur=$1; sub(/:$/,"",cur); on=(cur==job); next} inj && on{print}' "$1"; }
jobs_of() { awk '/^jobs:/{inj=1; next} inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/{c=$1; sub(/:$/,"",c); print c}' "$1"; }
nocomments() { grep -vE '^[[:space:]]*#'; }
# pyver: the python-version of the first setup-python step on stdin
pyver() { awk '/actions\/setup-python@/{on=1} on && /python-version:/{gsub(/.*python-version:[ ]*"?/,""); gsub(/"?[ ]*$/,""); print; exit}'; }

# ---- A. pins ---------------------------------------------------------------------------------------
TABLE=$(cat <<'T'
actions/checkout 3d3c42e5aac5ba805825da76410c181273ba90b1 v7.0.1
actions/setup-node 949feb2413d6458794dcd2491c4babbbce0c15c1 v7.1.0
actions/setup-python 6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 v7.1.0
actions/cache 55cc8345863c7cc4c66a329aec7e433d2d1c52a9 v6.1.0
actions/configure-pages 45bfe0192ca1faeb007ade9deae92b16b8254a0d v6.0.0
actions/upload-pages-artifact fc324d3547104276b827a68afc52ff2a11cc49c9 v5.0.0
actions/deploy-pages 368f82528645a54fb793d4d04e342629a3f51346 v5.0.1
dtolnay/rust-toolchain 683b588c487a69d01f6c6ddf40f036ff682cc2c8 v1
Swatinem/rust-cache d1527c8f67ef9af357290475d4af4b0fab8f12e0 v2.9.3
actions/upload-artifact cf430e030ddbb5b0abf93d22962f4752f3646cd9 v7.0.2
actions/download-artifact 9000827ccba6bdab643e8b6fd33ac0654aef8333 v8.0.2
github/codeql-action/init 33d7b85da1a04171e211befe2c739303b9a4c066 v4
github/codeql-action/analyze 33d7b85da1a04171e211befe2c739303b9a4c066 v4
github/codeql-action/upload-sarif 33d7b85da1a04171e211befe2c739303b9a4c066 v4
ossf/scorecard-action fa7117db83c52d787ae5a89f350999701505d78e v2.5.0
T
)
echo "== A. every uses: is a SHA-pinned row of the conventions table"
BADPIN=0; NUSES=0
while IFS= read -r line; do
  NUSES=$((NUSES+1))
  spec=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(- )?uses:[[:space:]]*//')
  if [[ "$spec" =~ ^([A-Za-z0-9._/-]+)@([0-9a-f]{40})[[:space:]]+#[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]*$ ]]; then
    if ! printf '%s\n' "$TABLE" | grep -qxF "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"; then
      echo "  not a table row: $spec"; BADPIN=$((BADPIN+1)); fi
  else
    echo "  not 'owner/repo@<40-hex> # <tag>': $spec"; BADPIN=$((BADPIN+1))
  fi
done < <(grep -hE '^[[:space:]]*(- )?uses:' "$WF"/*.yml)
expect_eq "all $NUSES uses: lines match the table (SHA and tag)" 0 "$BADPIN"

# ---- B. the determinism job installs numpy and Pillow by hash (S1-117) -----------------------------
echo "== B. determinism job: exact Python, hashed numpy and Pillow"
D=$(job_text "$CI" determinism)
if [ -z "$D" ]; then fail "job 'determinism' not found in ci.yml"; else
  DC=$(printf '%s\n' "$D" | nocomments)
  PYV=$(printf '%s\n' "$DC" | pyver)
  if [[ "$PYV" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "setup-python pins an exact python-version ($PYV)"; else fail "setup-python pins an exact python-version x.y.z (got '${PYV:-none}')"; fi
  HASHED=$(printf '%s\n' "$DC" | grep -E 'pip install' | grep -F -- '--require-hashes' | grep -F -- '--no-deps' | grep -F -- '--only-binary=:all:' | grep -cF 'tools/ci/requirements-determinism.txt')
  expect_eq "the determinism job runs pip install --require-hashes --no-deps --only-binary=:all: -r tools/ci/requirements-determinism.txt" 1 "$HASHED"
  expect_eq "that install uses the interpreter of the bench venv (\$BENCH_VENV_BIN), the same on Linux, macOS and Windows" 1 "$(printf '%s\n' "$DC" | grep -E 'requirements-determinism.txt' | grep -cF 'BENCH_VENV_BIN')"
  expect_eq "the determinism job no longer installs bench/requirements.txt" 0 "$(printf '%s\n' "$DC" | grep -cF 'bench/requirements.txt')"
  expect_eq "every pip install in the determinism job says --require-hashes" 0 "$(printf '%s\n' "$DC" | grep -E 'pip install' | grep -vcF -- '--require-hashes')"
  expect_eq "the determinism job runs on ubuntu, macos and windows" 1 "$(printf '%s\n' "$D" | grep -cE 'os: \[ubuntu-latest, macos-latest, windows-latest\]')"
fi
REQ=$TOOLS/requirements-determinism.txt
if [ ! -f "$REQ" ]; then fail "tools/ci/requirements-determinism.txt exists"; else
  ok "tools/ci/requirements-determinism.txt exists"
  for pkg in numpy pillow; do
    expect_eq "$pkg is pinned with == in the hashed file" 1 "$(grep -ciE "^$pkg==[0-9][^ ]* \\\\" "$REQ")"
    n=$(awk -v p="$pkg" 'BEGIN{IGNORECASE=1} $0 ~ "^"p"==" {on=1; next} on && /^[A-Za-z0-9]/ {on=0} on && /--hash=sha256:[0-9a-f]{64}/ {c++} END{print c+0}' "$REQ")
    if [ "$n" -ge 6 ]; then ok "$pkg has $n hash lines (one per platform wheel and Python)"; else fail "$pkg has at least 6 hash lines (got $n)"; fi
  done
  expect_eq "every requirement line of the hashed file is == pinned (no unpinned or ranged package)" 0 "$(grep -E '^[A-Za-z0-9]' "$REQ" | grep -cvE '^[A-Za-z0-9_.-]+==')"
fi

# ---- C. the wheels job (D2-05) ---------------------------------------------------------------------
echo "== C. wheels job: hashed tools, no cache, contents: read, --locked, artefacts only"
W=$(job_text "$CI" wheels)
if [ -z "$W" ]; then fail "job 'wheels' not found in ci.yml"; else
  WC=$(printf '%s\n' "$W" | nocomments)
  expect_eq "wheels: matrix covers ubuntu, windows and macos" 1 "$(printf '%s\n' "$WC" | grep -cE 'os: \[ubuntu-latest, windows-latest, macos-latest\]')"
  expect_eq "wheels: job-level permissions is contents: read" 1 "$(printf '%s\n' "$WC" | awk '/^    permissions:/{p=1; next} p && /^      /{print; next} p{exit}' | grep -cE '^      contents: read$')"
  expect_eq "wheels: no other permission (no id-token, attestations, packages, pages, write)" 0 "$(printf '%s\n' "$WC" | awk '/^    permissions:/{p=1; next} p && /^      /{print; next} p{exit}' | grep -vcE '^      contents: read$')"
  expect_eq "wheels: no actions/cache and no Swatinem/rust-cache" 0 "$(printf '%s\n' "$WC" | grep -cE 'actions/cache@|Swatinem/rust-cache@')"
  expect_eq "wheels: no id-token or attestations anywhere" 0 "$(printf '%s\n' "$WC" | grep -cE 'id-token|attestations')"
  WPYV=$(printf '%s\n' "$WC" | pyver)
  if [[ "$WPYV" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "wheels: setup-python pins an exact python-version ($WPYV)"; else fail "wheels: setup-python pins an exact python-version x.y.z (got '${WPYV:-none}')"; fi
  expect_eq "wheels: tools come from tools/ci/requirements.txt with --require-hashes --no-deps --only-binary=:all:" 1 "$(printf '%s\n' "$WC" | grep -E 'pip install' | grep -F -- '--require-hashes' | grep -F -- '--no-deps' | grep -F -- '--only-binary=:all:' | grep -cF 'tools/ci/requirements.txt')"
  expect_eq "wheels: no pip install of anything else (only the hashed tools and the --no-index smoke install)" 0 "$(printf '%s\n' "$WC" | grep -E 'pip install' | grep -vE 'tools/ci/requirements.txt|--no-index' | wc -l | tr -d ' ')"
  expect_eq "wheels: no uvx, no pip install uv==, no npm install" 0 "$(printf '%s\n' "$WC" | grep -cE '(^|[^A-Za-z-])uvx |pip install uv==|npm (i|install|init)( |$)')"
  expect_eq "wheels: every cargo or maturin build/sdist line says --locked, or is the sdist (maturin sdist compiles nothing)" 0 "$(printf '%s\n' "$WC" | grep -E '(cargo (build|test|check|run|install|tree)|maturin (build|develop))' | grep -vcF -- '--locked')"
  expect_eq "wheels: maturin build is run with --locked" 1 "$([ "$(printf '%s\n' "$WC" | grep -E 'maturin build' | grep -cF -- '--locked')" -ge 2 ] && echo 1 || echo 0)"
  expect_eq "wheels: manylinux_2_17 through zig on ubuntu" 1 "$([ "$(printf '%s\n' "$WC" | grep -cE -- '--zig --compatibility manylinux_2_17')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "wheels: an sdist is built" 1 "$([ "$(printf '%s\n' "$WC" | grep -cE 'maturin sdist|--sdist|scripts/package-sdist.sh')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "wheels: the wheel is installed with --no-index and one real call is made" 1 "$([ "$(printf '%s\n' "$WC" | grep -cE 'pip install --no-index')" -ge 1 ] && [ "$(printf '%s\n' "$WC" | grep -cE 'analyse')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "wheels: tags are compared as expanded sets by tests/python/check_wheel.py" 1 "$([ "$(printf '%s\n' "$WC" | grep -cF 'tests/python/check_wheel.py')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "wheels: builder paths are checked (scripts/check-no-builder-paths.sh)" 1 "$([ "$(printf '%s\n' "$WC" | grep -cF 'check-no-builder-paths')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "wheels: SHA256SUMS is written with newline=\"\\n\" (LF on every runner, BUG-T2-S6-10)" 1 "$([ "$(printf '%s\n' "$WC" | grep -F 'SHA256SUMS' | grep -F 'write_text' | grep -cF 'newline="\n"')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "wheels: SHA256SUMS is written and printed" 1 "$([ "$(printf '%s\n' "$WC" | grep -cF 'SHA256SUMS')" -ge 2 ] && echo 1 || echo 0)"
  UP=$(printf '%s\n' "$WC" | grep -cE 'actions/upload-artifact@')
  expect_eq "wheels: exactly one upload-artifact step" 1 "$UP"
  expect_eq "wheels: retention-days: 14" 1 "$(printf '%s\n' "$WC" | grep -cE '^[[:space:]]*retention-days: 14$')"
  expect_eq "wheels: if-no-files-found: error" 1 "$(printf '%s\n' "$WC" | grep -cE '^[[:space:]]*if-no-files-found: error$')"
  expect_eq "wheels: the artefact path holds only wheels, the sdist and SHA256SUMS" 0 "$(printf '%s\n' "$WC" | awk '/actions\/upload-artifact@/{u=1} u && /path: \|/{p=1; next} p && /^            /{print; next} p{exit}' | grep -vcE 'target/wheels/(\*\.whl|\*\.tar\.gz|SHA256SUMS)')"
  expect_eq "wheels: no publish, release, registry, Pages or attestation step, no twine, no gh release" 0 "$(printf '%s\n' "$WC" | grep -ciE 'twine|pypi|npm publish|cargo publish|gh release|upload-pages|deploy-pages|attest|sigstore|cosign|slsa')"
  expect_eq "wheels: no secret" 0 "$(printf '%s\n' "$WC" | grep -cE 'secrets\.|GITHUB_TOKEN')"
fi
if [ -f "$TOOLS/requirements.txt" ]; then
  ok "tools/ci/requirements.txt exists"
  for pkg in uv maturin ziglang; do
    expect_eq "$pkg is pinned with == and carries hashes in tools/ci/requirements.txt" 1 "$(awk -v p="$pkg" '$0 ~ "^"p"==" {on=1; next} on && /^[A-Za-z0-9]/ {on=0} on && /--hash=sha256:[0-9a-f]{64}/ {c++} END{print (c>=1)?1:0}' "$TOOLS/requirements.txt")"
  done
  expect_eq "every requirement of tools/ci/requirements.txt is == pinned" 0 "$(grep -E '^[A-Za-z0-9]' "$TOOLS/requirements.txt" | grep -cvE '^[A-Za-z0-9_.-]+==')"
else
  fail "tools/ci/requirements.txt exists"
fi

# ---- D. general rules of ci.yml ---------------------------------------------------------------------
echo "== D. ci.yml: no pull_request_target, no secrets, no write token, per-job permissions"
CODE=$(nocomments < "$CI")
expect_eq "no pull_request_target" 0 "$(printf '%s\n' "$CODE" | grep -c 'pull_request_target')"
expect_eq "no secrets. reference" 0 "$(printf '%s\n' "$CODE" | grep -c 'secrets\.')"
expect_eq "no id-token: write and no pages: write" 0 "$(printf '%s\n' "$CODE" | grep -cE 'id-token: write|pages: write')"
NCHK=$(printf '%s\n' "$CODE" | grep -c 'actions/checkout@')
NPCF=$(printf '%s\n' "$CODE" | grep -c 'persist-credentials: false')
expect_eq "every checkout has persist-credentials: false ($NCHK checkouts)" "$NCHK" "$NPCF"
BAD=0
for j in $(jobs_of "$CI"); do
  job_text "$CI" "$j" | grep -qE '^    permissions:' || { echo "  job $j sets no permissions"; BAD=$((BAD+1)); }
done
expect_eq "every job sets its own permissions" 0 "$BAD"
finish
