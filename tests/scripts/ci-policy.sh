#!/usr/bin/env bash
# The CI rules of Sprint 6 (S1-079, S1-117, TD-09) checked on the committed workflow files and requirement files, without
# the network. It does not replace running the workflows; it keeps the rules from drifting. Red before .github/workflows/ci.yml
# was changed (red/D2-04-ci-policy.log), green after.
#
#  A. every `uses:` in .github/workflows/*.yml is owner/repo@<40-hex SHA> # <tag>, and the (action, SHA, tag) triple is a row of
#     the conventions table below (no new action);
#  B. S1-117, the determinism job: setup-python takes an exact CPython 3.12.z per OS from the matrix (macOS and Windows 3.12.10,
#     the last 3.12 with binaries there; Linux 3.12.13 or newer, the only 3.12 on the ubuntu-26.04 image); numpy and Pillow come from the hashed
#     tools/ci/requirements-determinism.txt through `pip install --require-hashes --no-deps --only-binary=:all:` on every OS;
#     bench/requirements.txt (loose lower bounds) is no longer installed by CI; the hashed file pins both with == and
#     carries at least one hash per platform wheel;
#  C. the release-rehearsal job (TD-106, Sprint 7; it replaced and absorbed the `wheels` job of TD-09, S1-079): matrix ubuntu, windows
#     and macos; contents: read at job level and no id-token or attestations anywhere; no cache of any kind (no actions/cache, no
#     Swatinem/rust-cache, no `cache:` input); tools from tools/ci/requirements.txt with --require-hashes --no-deps
#     --only-binary=:all: and the same exact per-OS Python as job B; every cargo and maturin build line, in the workflow and in
#     scripts/release/, says --locked; manylinux_2_17 through zig on ubuntu; an sdist; the crates packaged and installed from the
#     packaged .crate files (offline, source replacement, never `cargo install --path crates/`); installs with --no-index and a real
#     call; the rehearsal steps in order (build, install, sign, gate), the README quick start, the publish dry run; one upload-artifact
#     step named REHEARSAL-test-key-NOT-A-RELEASE-pagetriage-<os>-<sha> holding exactly dist-release/ and dist-release-report/,
#     retention-days: 3, if-no-files-found: error, include-hidden-files: false; no publish, release, registry or Pages step and no secret;
#  D. ci.yml: no pull_request_target, no `secrets.`, no pages: write or id-token: write; every checkout has
#     persist-credentials: false; every job sets its own permissions;
#  F. publish.yml (TD-105, Sprint 7; D2-03): it exists but cannot fire by accident. workflow_dispatch only (no inputs, no push, no pull
#     request, no schedule, no other workflow), top-level permissions: {}, a repository and main-branch guard on both jobs, the `release`
#     environment on the publish job, the RELEASE_PUBLISH_ARMED variable read in the first step after the checkout (a variable of the
#     environment is not visible to a job-level `if`, and no `vars.` is read in any `if`; TD-125), id-token and attestations only there, secrets only as
#     NPM_TOKEN and CARGO_REGISTRY_TOKEN in the step env of the publish job, lock 6 (RELEASE_KEY_ID), the three bindings, the signed manifest
#     verified against docs/release-keys.json with --expect-id, artefacts of THIS run only, exact file paths, provenance after the checks and
#     before the first publish step, npm with --provenance --access public --ignore-scripts and a derived dist-tag, PyPI through
#     pypa/gh-action-pypi-publish with attestations: true and packages-dir, the crates re-packaged (`cargo package --locked --no-verify`),
#     compared, published (`cargo publish --locked --no-verify`) and read back from the crates.io sparse index as four consecutive steps
#     BEFORE the PyPI step (S1-126, S1-131), no test-key string, no cache, 1-day candidate upload;
#  H. every dtolnay/rust-toolchain step installs the channel, components and targets that rust-toolchain.toml lists, so no `cargo` call
#     starts a rustup implicit install (run 44651022212: 'detected conflict: bin/cargo-clippy' on Linux and macOS);
#  E. all workflows (Sprint 7): no pull_request_target and no workflow_run anywhere; `secrets.` only as NPM_TOKEN or
#     CARGO_REGISTRY_TOKEN in publish.yml; id-token: write and attestations: write only in publish.yml; no `inputs.` and no
#     `github.event.` in a workflow other than the pre-Sprint-7 ones; no version or matrix value interpolated into a run: line.
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
# py_pins: "<os> <python>" for every matrix.include entry on stdin (comments already stripped)
py_pins() { awk '/^[[:space:]]*- os:/{os=$3} /^[[:space:]]*python:/{v=$2; gsub(/"/,"",v); print os, v}'; }
# check_pins <label> <python-version as written in the setup-python step> <pins>: one exact CPython 3.12.z per OS, the hashed
# files being compiled for cp312. actions/python-versions (versions-manifest.json, read 19 Nov 2026): 3.12.10 is the last 3.12 with
# a darwin or win32 build; 3.12.11 and 3.12.12 exist for Ubuntu 22.04 and 24.04 only; ubuntu-26.04 has 3.12.13 and newer only. No
# single patch release exists on all three runner images, so the pin is per OS (run 44580200515).
check_pins() {
  local label=$1 pv=$2 pins=$3 os v n re why
  expect_eq "$label: setup-python reads python-version from the matrix" '${{ matrix.python }}' "$pv"
  for os in ubuntu-latest macos-latest windows-latest; do
    n=$(printf '%s\n' "$pins" | awk -v o="$os" '$1==o' | wc -l | tr -d ' ')
    v=$(printf '%s\n' "$pins" | awk -v o="$os" '$1==o{print $2; exit}')
    expect_eq "$label: exactly one Python pin for $os" 1 "$n"
    case "$os" in
      ubuntu-latest) re='^3\.12\.(1[3-9]|[2-9][0-9])$'; why='the ubuntu-26.04 image has only 3.12.13 and newer in actions/python-versions' ;;
      *) re='^3\.12\.10$'; why='3.12.10 is the last CPython 3.12 with a macOS and a Windows build in actions/python-versions' ;;
    esac
    if [[ "$v" =~ $re ]]; then ok "$label: $os pins CPython $v"; else fail "$label: $os must pin $re because $why (got '${v:-none}')"; fi
  done
}

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
actions/attest-build-provenance 4d101475d8b20a2381f78447822ac1eab6504dd8 v4.2.2
pypa/gh-action-pypi-publish 7245906fb61fa33a13554f9d5fb856fe61758086 v1.14.3
T
)
echo "== A. every uses: is a SHA-pinned row of the conventions table"
BADPIN=0; NUSES=0
while IFS= read -r line; do
  NUSES=$((NUSES+1))
  spec=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(- )?uses:[[:space:]]*//')
  if [[ "$spec" =~ ^([A-Za-z0-9._/-]+)@([0-9a-f]{40})[[:space:]]+#[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]*$ ]]; then
    if ! printf '%s\n' "$TABLE" | gq -xF "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"; then
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
  DPINS=$(printf '%s\n' "$DC" | py_pins)
  check_pins "determinism" "$(printf '%s\n' "$DC" | pyver)" "$DPINS"
  HASHED=$(printf '%s\n' "$DC" | grep -E 'pip install' | grep -F -- '--require-hashes' | grep -F -- '--no-deps' | grep -F -- '--only-binary=:all:' | grep -cF 'tools/ci/requirements-determinism.txt')
  expect_eq "the determinism job runs pip install --require-hashes --no-deps --only-binary=:all: -r tools/ci/requirements-determinism.txt" 1 "$HASHED"
  expect_eq "that install uses the interpreter of the bench venv (\$BENCH_VENV_BIN), the same on Linux, macOS and Windows" 1 "$(printf '%s\n' "$DC" | grep -E 'requirements-determinism.txt' | grep -cF 'BENCH_VENV_BIN')"
  expect_eq "the determinism job no longer installs bench/requirements.txt" 0 "$(printf '%s\n' "$DC" | grep -cF 'bench/requirements.txt')"
  expect_eq "every pip install in the determinism job says --require-hashes" 0 "$(printf '%s\n' "$DC" | grep -E 'pip install' | grep -vcF -- '--require-hashes')"
  expect_eq "the determinism job runs on ubuntu, macos and windows" 1 "$(printf '%s\n' "$D" | grep -cE 'os: \[ubuntu-latest, macos-latest, windows-latest\]')"
fi
for f in requirements.txt requirements-determinism.txt; do
  expect_eq "tools/ci/$f is compiled for CPython 3.12 (--python-version 3.12), the minor the Python pins name" 1 "$(grep -cE -- '^#[[:space:]]+uv pip compile .*--python-version 3\.12 ' "$TOOLS/$f" 2>/dev/null)"
done
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

# ---- C. the release-rehearsal job (TD-106) ---------------------------------------------------------
echo "== C. release-rehearsal job: hashed tools, no cache, contents: read, --locked, offline crate install, the rehearsal, 3-day upload"
expect_eq "the wheels job is folded into release-rehearsal (no job named wheels remains)" 0 "$(jobs_of "$CI" | grep -cx wheels)"
W=$(job_text "$CI" release-rehearsal)
if [ -z "$W" ]; then fail "job 'release-rehearsal' not found in ci.yml"; else
  WC=$(printf '%s\n' "$W" | nocomments)
  RH=$REPO/scripts/release/rehearse.sh
  RS=""; for f in "$REPO"/scripts/release/*.sh; do [ -f "$f" ] && RS="$RS$(nocomments < "$f")
"; done
  expect_eq "release-rehearsal: the job name is 'release-rehearsal (\${{ matrix.os }})'" 1 "$(printf '%s\n' "$WC" | grep -cF 'name: release-rehearsal (${{ matrix.os }})')"
  expect_eq "release-rehearsal: matrix covers ubuntu, windows and macos" 1 "$(printf '%s\n' "$WC" | grep -cE 'os: \[ubuntu-latest, windows-latest, macos-latest\]')"
  expect_eq "release-rehearsal: fail-fast is false" 1 "$(printf '%s\n' "$WC" | grep -cE '^[[:space:]]*fail-fast: false$')"
  expect_eq "release-rehearsal: job-level permissions is contents: read" 1 "$(printf '%s\n' "$WC" | awk '/^    permissions:/{p=1; next} p && /^      /{print; next} p{exit}' | grep -cE '^      contents: read$')"
  expect_eq "release-rehearsal: no other permission (no id-token, attestations, packages, pages, write)" 0 "$(printf '%s\n' "$WC" | awk '/^    permissions:/{p=1; next} p && /^      /{print; next} p{exit}' | grep -vcE '^      contents: read$')"
  expect_eq "release-rehearsal: every step runs in bash (the job sets defaults.run.shell: bash), also on Windows" 1 "$(printf '%s\n' "$WC" | awk '/^    defaults:/{d=1; next} d && /^      run:/{r=1; next} d && r && /^        shell: bash$/{print "yes"; exit} d && !/^      /{exit}' | grep -c yes)"
  expect_eq "release-rehearsal: a timeout is set" 1 "$(printf '%s\n' "$WC" | grep -cE '^    timeout-minutes: [0-9]+$')"
  expect_eq "release-rehearsal: no cache of any kind (no actions/cache, no rust-cache, no cache: input)" 0 "$(printf '%s\n' "$WC" | grep -cE 'actions/cache|Swatinem/rust-cache|^[[:space:]]*cache:|cache-dependency-path|cache-directories')"
  expect_eq "release-rehearsal: no id-token or attestations anywhere" 0 "$(printf '%s\n' "$WC" | grep -cE 'id-token|attestations')"
  WPINS=$(printf '%s\n' "$WC" | py_pins)
  check_pins "release-rehearsal" "$(printf '%s\n' "$WC" | pyver)" "$WPINS"
  expect_eq "release-rehearsal and determinism pin the same Python on every OS" "$(printf '%s\n' "${DPINS:-}" | sort)" "$(printf '%s\n' "$WPINS" | sort)"
  expect_eq "release-rehearsal: setup-node 22 without a cache input" 1 "$(printf '%s\n' "$WC" | grep -cE '^[[:space:]]*node-version: "22"$')"
  expect_eq "release-rehearsal: tools come from tools/ci/requirements.txt with --require-hashes --no-deps --only-binary=:all:" 1 "$(printf '%s\n' "$WC" | grep -E 'pip install' | grep -F -- '--require-hashes' | grep -F -- '--no-deps' | grep -F -- '--only-binary=:all:' | grep -cF 'tools/ci/requirements.txt')"
  expect_eq "release-rehearsal: no other pip install in the workflow job" 0 "$(printf '%s\n' "$WC" | grep -E 'pip install' | grep -vcE 'tools/ci/requirements.txt')"
  expect_eq "release-rehearsal: every pip install in scripts/release/ is a hashed tool install or an artefact install with --no-index --no-deps" 0 "$(printf '%s\n' "$RS" | grep -E 'pip install' | grep -vE -- '--require-hashes .*--no-deps.*--only-binary=:all:.*tools/ci/requirements.txt|--no-index --no-deps' | wc -l | tr -d ' ')"
  expect_eq "release-rehearsal: no uvx, no pip install uv==, no npm install of a registry package" 0 "$( { printf '%s\n' "$WC"; printf '%s\n' "$RS"; } | grep -cE '(^|[^A-Za-z-])uvx |pip install uv==')"
  expect_eq "release-rehearsal: every cargo and maturin build, package, vendor, install or tree line says --locked (workflow and scripts/release/)" 0 "$( { printf '%s\n' "$WC"; printf '%s\n' "$RS"; } | grep -E '(^|[^A-Za-z_-])(cargo (build|test|check|run|install|tree|package|publish|vendor)|maturin (build|develop))( |$)' | grep -vE '^[[:space:]]*(echo|printf|die|log)|die "|echo "|printf |cargo publish' | grep -vcF -- '--locked')"
  expect_eq "release-rehearsal: cargo package --locked -p pagetriage-core -p pagetriage-cli is run twice (the packaged crates are what gets signed; not the publish = false crates)" 1 "$([ "$(printf '%s\n' "$RS" | grep -cE 'cargo package --locked( --no-verify)? -p pagetriage-core -p pagetriage-cli')" -ge 2 ] && echo 1 || echo 0)"
  expect_eq "release builds: build-artefacts.sh defaults SOURCE_DATE_EPOCH to the commit time (git log -1 --format=%ct) unless the caller sets one, so the sdist and the wheel of a rehearsal build equal those of the publish build of the same commit (S1-135: the sdist and the wheel change with the epoch)" 1 "$([ "$(nocomments < "$REPO/scripts/release/build-artefacts.sh" | grep -cF 'SOURCE_DATE_EPOCH=$(git log -1 --format=%ct')" -ge 1 ] && [ "$(nocomments < "$REPO/scripts/release/build-artefacts.sh" | grep -cF 'export SOURCE_DATE_EPOCH')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: manylinux_2_17 through zig on ubuntu" 1 "$([ "$(printf '%s\n' "$RS" | grep -cE -- '--zig --compatibility manylinux_2_17')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: an sdist is built, and a wheel is built from the sdist alone with --locked" 1 "$([ "$(printf '%s\n' "$RS" | grep -cF 'scripts/package-sdist.sh')" -ge 1 ] && [ "$(printf '%s\n' "$RS" | grep -E 'maturin build' | grep -cF 'wheel')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: the wheels are installed with --no-index and checked by a real call (check-installed.py)" 1 "$([ "$(printf '%s\n' "$RS" | grep -cE 'pip install --no-index')" -ge 1 ] && [ -f "$REPO/scripts/release/check-installed.py" ] && [ "$(printf '%s\n' "$RS" | grep -cF 'check-installed.py')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: the npm tarball is installed offline with --ignore-scripts and a fresh cache, then a real call (check-installed.cjs)" 1 "$([ "$(printf '%s\n' "$RS" | grep -F 'npm install' | grep -F -- '--ignore-scripts' | grep -cF 'npm_config_offline=true')" -ge 1 ] && [ "$(printf '%s\n' "$RS" | grep -cF 'check-installed.cjs')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: the command publish.yml runs (cargo package --locked --no-verify -p pagetriage-core -p pagetriage-cli) is run in the rehearsal and its bytes are compared with the verified ones (S1-131)" 1 "$([ "$(printf '%s\n' "$RS" | grep -cF 'cargo package --locked --no-verify -p pagetriage-core -p pagetriage-cli')" -ge 1 ] && [ "$(printf '%s\n' "$RS" | grep -cF 'the --no-verify bytes equal the verified bytes')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: tags are compared as expanded sets by tests/python/check_wheel.py (the publish dry run runs it on every wheel)" 1 "$([ "$(printf '%s\n' "$RS" | grep -cF 'tests/python/check_wheel.py')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: builder paths are checked (scripts/check-no-builder-paths.sh)" 1 "$([ "$(printf '%s\n' "$RS" | grep -cF 'check-no-builder-paths')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: the CLI is installed from the packaged crates by scripts/release/install-crate-offline.sh" 1 "$([ "$(printf '%s\n' "$RS" | grep -cF 'install-crate-offline.sh')" -ge 1 ] && [ -f "$REPO/scripts/release/install-crate-offline.sh" ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: no 'cargo install --path crates/' anywhere (workflow and scripts/release/)" 0 "$( { printf '%s\n' "$WC"; printf '%s\n' "$RS"; } | grep -cE 'cargo install .*--path[ =]+"?(\./)?crates/')"
  expect_eq "release-rehearsal: every cargo install says --offline --locked and a --path, and the script replaces crates-io with a directory source" 1 "$( { printf '%s\n' "$WC"; printf '%s\n' "$RS"; } | grep -E '^[[:space:]]*\( cd .*cargo install|^[[:space:]]*cargo install' | grep -F -- '--offline' | grep -F -- '--locked' | grep -cF -- '--path' | awk '{print ($1>=1)?1:0}')$([ "$(printf '%s\n' "$RS" | grep -cE 'replace-with = "vendored-sources"|directory = ')" -ge 2 ] && echo "" || echo x)"
  expect_eq "release-rehearsal: the rehearsal steps run in order: build, install, sign, gate" "build install sign gate" "$(printf '%s\n' "$WC" | grep -oE 'rehearse\.sh (build|install|sign|gate)' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
  expect_eq "release-rehearsal: the README quick start runs from the built artefacts (QUICKSTART_RUN=1 QUICKSTART_REUSE=1)" 1 "$(printf '%s\n' "$WC" | grep -E 'tests/scripts/quickstart.sh' | grep -F 'QUICKSTART_RUN=1' | grep -cF 'QUICKSTART_REUSE=1')"
  expect_eq "release-rehearsal: the publish dry run (scripts/release/publish-dry-run.sh) runs in CI" 1 "$(printf '%s\n' "$WC" | grep -cF 'scripts/release/publish-dry-run.sh')"
  expect_eq "release-rehearsal: wasm tools come from the digest-pinned installer" 1 "$(printf '%s\n' "$WC" | grep -cF 'scripts/install-wasm-tools.sh')"
  expect_eq "release-rehearsal: the rehearsal script uses the vendored release tool and the TEST key only through the tool's own flag" 1 "$([ "$(printf '%s\n' "$RS" | grep -cF 'scripts/release/release-tool.mjs')" -ge 1 ] && [ "$(printf '%s\n' "$RS" | grep -cF -- '--test-key rfc8032-1')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: refusal proofs check an exact exit code and the first stderr line, and the self-test points at a missing tool" 1 "$([ "$(printf '%s\n' "$RS" | grep -cF 'refused: test_key_refused')" -ge 1 ] && [ "$(printf '%s\n' "$RS" | grep -cF 'refused: no_trusted_key')" -ge 1 ] && [ "$(printf '%s\n' "$RS" | grep -cF 'does-not-exist.mjs')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "release-rehearsal: no secret, no token, no GITHUB_SHA or GITHUB_REF read by the scripts" 0 "$( { printf '%s\n' "$WC" | grep -E 'secrets\.|GITHUB_TOKEN'; printf '%s\n' "$RS" | grep -E 'GITHUB_SHA|GITHUB_REF'; } | grep -cv '^$')"
  UPC=$(printf '%s\n' "$WC" | grep -cE 'actions/upload-artifact@')
  expect_eq "release-rehearsal: exactly one upload-artifact step" 1 "$UPC"
  expect_eq "release-rehearsal: the artefact is named REHEARSAL-test-key-NOT-A-RELEASE-pagetriage-<os>-<sha>" 1 "$(printf '%s\n' "$WC" | grep -cF 'name: REHEARSAL-test-key-NOT-A-RELEASE-pagetriage-${{ matrix.os }}-${{ github.sha }}')"
  expect_eq "release-rehearsal: the artefact path is exactly dist-release/ and dist-release-report/" "dist-release/
dist-release-report/" "$(printf '%s\n' "$WC" | awk '/actions\/upload-artifact@/{u=1} u && /path: \|/{p=1; next} p && /^            /{gsub(/^ +/,""); print; next} p{exit}')"
  expect_eq "release-rehearsal: retention-days: 3" 1 "$(printf '%s\n' "$WC" | grep -cE '^[[:space:]]*retention-days: 3$')"
  expect_eq "release-rehearsal: if-no-files-found: error" 1 "$(printf '%s\n' "$WC" | grep -cE '^[[:space:]]*if-no-files-found: error$')"
  expect_eq "release-rehearsal: include-hidden-files: false" 1 "$(printf '%s\n' "$WC" | grep -cE '^[[:space:]]*include-hidden-files: false$')"
  expect_eq "release-rehearsal: no publish, release, registry or Pages step, no twine, no gh release, no attestation" 0 "$(printf '%s\n' "$WC" | grep -vE 'publish-dry-run' | grep -ciE 'twine|pypi|npm publish|cargo publish|gh release|upload-pages|deploy-pages|attest|sigstore|cosign|slsa')"
fi
# the sdist's name is the PEP 440 version (found by the first full local rehearsal with REHEARSE_SDIST=1: 'dist/sdist/pagetriage-<semver>.tar.gz was not written')
SD=$(nocomments < "$REPO/scripts/package-sdist.sh")
expect_eq "package-sdist.sh names the sdist with the PEP 440 version (py_version), not the SemVer one" 1 "$([ "$(printf '%s\n' "$SD" | grep -cF 'py_version')" -ge 1 ] && [ "$(printf '%s\n' "$SD" | grep -c 'pagetriage-\$PYVER')" -ge 3 ] && [ "$(printf '%s\n' "$SD" | grep -c 'pagetriage-\$VERSION')" = 0 ] && echo 1 || echo 0)"
RHS=$REPO/scripts/release/rehearse.sh
if [ -f "$RHS" ]; then
  ok "scripts/release/rehearse.sh exists"
  expect_eq "rehearse.sh: the TEST key is only ever used with the tool's explicit flags (no key file is read, no seed is written down)" 0 "$(nocomments < "$RHS" | grep -ciE '9d61b19d|key\.secret|--key ')"
  expect_eq "rehearse.sh: it never reads GITHUB_SHA or GITHUB_REF" 0 "$(nocomments < "$RHS" | grep -cE 'GITHUB_SHA|GITHUB_REF')"
else
  fail "scripts/release/rehearse.sh exists"
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
  # gq, not grep -q: the determinism job's text is over 4096 bytes and grep -q would leave awk writing to a closed pipe (lib.sh, CI run 44656239981)
  job_text "$CI" "$j" | gq -E '^    permissions:' || { echo "  job $j sets no permissions"; BAD=$((BAD+1)); }
done
expect_eq "every job sets its own permissions" 0 "$BAD"

# ---- E. all workflows -------------------------------------------------------------------------------
echo "== E. all workflows: no pull_request_target or workflow_run; secrets, id-token and attestations only in publish.yml"
ALLC=""; for f in "$WF"/*.yml; do ALLC="$ALLC$(nocomments < "$f")
"; done
expect_eq "no pull_request_target and no workflow_run in any workflow" 0 "$(printf '%s\n' "$ALLC" | grep -cE 'pull_request_target|workflow_run')"
NONPUB=""; for f in "$WF"/*.yml; do [ "$(basename "$f")" = publish.yml ] || NONPUB="$NONPUB$(nocomments < "$f")
"; done
expect_eq "outside publish.yml: no secrets. reference" 0 "$(printf '%s\n' "$NONPUB" | grep -c 'secrets\.')"
expect_eq "outside publish.yml: no attestations: write" 0 "$(printf '%s\n' "$NONPUB" | grep -c 'attestations: write')"
# FR2: every upload step in every workflow writes include-hidden-files: false out (the stats.yml one was the last without)
UPL=0; HID=0; for f in "$WF"/*.yml; do n=$(nocomments < "$f" | grep -c 'actions/upload-artifact@'); h=$(nocomments < "$f" | grep -cE '^[[:space:]]*include-hidden-files: false$'); UPL=$((UPL+n)); HID=$((HID+h)); done
expect_eq "every actions/upload-artifact step in every workflow sets include-hidden-files: false" "$UPL" "$HID"
if [ -f "$WF/publish.yml" ]; then
  PC=$(nocomments < "$WF/publish.yml")
  expect_eq "publish.yml: secrets. is only NPM_TOKEN or CARGO_REGISTRY_TOKEN" 0 "$(printf '%s\n' "$PC" | grep -E 'secrets\.' | grep -vcE 'secrets\.(NPM_TOKEN|CARGO_REGISTRY_TOKEN)\b')"
fi
# inputs. and github.event. never appear in the workflows written in Sprint 7 (ci.yml, publish.yml)
expect_eq "ci.yml: no inputs. and no github.event. expression" 0 "$(printf '%s\n' "$CODE" | grep -cE '\$\{\{[^}]*(inputs\.|github\.event\.)')"
# no expression inside a run: step (a version or matrix value reaches a script only through env)
RUNEXPR=$(printf '%s\n' "$CODE" | awk '/^[[:space:]]*(- )?run:/{ind=match($0,/[^ ]/); if ($0 ~ /run:[[:space:]]*[|>]/) {inblk=1; blkind=ind; next} else {print; next}} inblk{ if ($0 ~ /^[[:space:]]*$/) next; cur=match($0,/[^ ]/); if (cur>blkind+1) {print; next} else {inblk=0} }' | grep -c '\${{')
expect_eq "ci.yml: no \${{ }} expression inside a run: step (values reach scripts through env)" 0 "$RUNEXPR"

# ---- F. publish.yml ---------------------------------------------------------------------------------
echo "== F. publish.yml: workflow_dispatch only, six locks, three bindings, provenance, then publishing; nobody runs it"
PUB=$WF/publish.yml
if [ ! -f "$PUB" ]; then fail ".github/workflows/publish.yml exists"; else
  ok ".github/workflows/publish.yml exists"
  PC=$(nocomments < "$PUB")
  ON=$(printf '%s\n' "$PC" | awk '/^on:/{on=1; next} on && /^[^ ]/{exit} on{print}')
  expect_eq "publish.yml: the only trigger is workflow_dispatch" "workflow_dispatch:" "$(printf '%s\n' "$ON" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/ $//')"
  expect_eq "publish.yml: no inputs, no github.event, no secrets outside NPM_TOKEN and CARGO_REGISTRY_TOKEN" 0 "$(( $(printf '%s\n' "$PC" | grep -cE '(^|[^A-Za-z_])inputs\.|github\.event\.|^[[:space:]]+inputs:') + $(printf '%s\n' "$PC" | grep -E 'secrets\.' | grep -vcE 'secrets\.(NPM_TOKEN|CARGO_REGISTRY_TOKEN)\b') ))"
  expect_eq "publish.yml: no pull_request, pull_request_target, push, schedule, release, workflow_run or workflow_call trigger" 0 "$(printf '%s\n' "$PC" | grep -cE '^[[:space:]]*(pull_request|pull_request_target|push|schedule|release|workflow_run|workflow_call|repository_dispatch):')"
  expect_eq "publish.yml: top-level permissions: {}" 1 "$(printf '%s\n' "$PC" | grep -cE '^permissions: \{\}$')"
  expect_eq "publish.yml: concurrency group, never cancelled mid-publish" 1 "$(printf '%s\n' "$PC" | awk '/^concurrency:/{c=1; next} c && /^[^ ]/{exit} c{print}' | grep -cE 'cancel-in-progress: false')"
  expect_eq "publish.yml: exactly two jobs, build and publish" "build publish" "$(jobs_of "$PUB" | tr '\n' ' ' | sed 's/ $//')"
  expect_eq "publish.yml: the build and publish job names are 'build (\${{ matrix.os }})' and 'publish'" 2 "$([ "$(printf '%s\n' "$PC" | grep -cF 'name: build (${{ matrix.os }})')" = 1 ] && [ "$(printf '%s\n' "$PC" | grep -cxF '    name: publish')" = 1 ] && echo 2 || echo 0)"
  expect_eq "publish.yml: every job sets its own permissions" 0 "$(for j in $(jobs_of "$PUB"); do job_text "$PUB" "$j" | gq -E '^    permissions:' || echo "$j"; done | wc -l | tr -d ' ')"
  PB=$(job_text "$PUB" build | nocomments); PP=$(job_text "$PUB" publish | nocomments)
  # locks 1 and 3: repository and branch guards on both jobs, the armed variable on publish
  expect_eq "publish.yml: both jobs carry the repository and main-branch guard (lock 1)" 2 "$(printf '%s\n%s\n' "$PB" "$PP" | grep -cF "if: github.repository == 'AirplaneMode-Labs/pagetriage' && github.ref == 'refs/heads/main'")"
  # lock 3 (TD-125): RELEASE_PUBLISH_ARMED is a variable of the 'release' environment, which a job-level `if` cannot read. It is read in the
  # step env of the first step after the checkout, and no `if:` anywhere in the file reads `vars.`.
  expect_eq "publish.yml: no if: (job-level or step-level) reads vars. (an environment variable is not visible to a job-level if; TD-125)" 0 "$(printf '%s\n' "$PC" | grep -cE '^[[:space:]]*(- )?if:.*vars\.')"
  expect_eq "publish.yml: the publish job's if is exactly the repository and main-branch guard" 1 "$(printf '%s\n' "$PP" | grep -cE "^    if: github.repository == 'AirplaneMode-Labs/pagetriage' && github.ref == 'refs/heads/main'$")"
  expect_eq "publish.yml: vars.RELEASE_PUBLISH_ARMED appears once, as the ARMED step env, and vars.RELEASE_KEY_ID once, as the RELEASE_KEY_ID step env" 1 "$([ "$(printf '%s\n' "$PC" | grep -c 'vars\.RELEASE_PUBLISH_ARMED')" = 1 ] && [ "$(printf '%s\n' "$PC" | grep -cE '^          ARMED: \$\{\{ vars\.RELEASE_PUBLISH_ARMED \}\}$')" = 1 ] && [ "$(printf '%s\n' "$PC" | grep -c 'vars\.RELEASE_KEY_ID')" = 1 ] && [ "$(printf '%s\n' "$PC" | grep -cE '^          RELEASE_KEY_ID: \$\{\{ vars\.RELEASE_KEY_ID \}\}$')" = 1 ] && echo 1 || echo 0)"
  step_n() { printf '%s\n' "$PP" | awk -v n="$1" '/^      - /{c++} c==n{print}'; }   # the text of step n (1-based) of the publish job
  expect_eq "publish.yml: the first step of the publish job is the checkout" 1 "$(step_n 1 | grep -c 'actions/checkout@')"
  expect_eq "publish.yml: the armed step is the first step after the checkout (lock 3: ARMED from the step env, publish-guard.sh armed)" 2 "$([ "$(step_n 2 | grep -cE '^          ARMED: \$\{\{ vars\.RELEASE_PUBLISH_ARMED \}\}$')" = 1 ] && [ "$(step_n 2 | grep -cE '^        run: bash scripts/release/publish-guard\.sh armed$')" = 1 ] && echo 2 || echo 0)"
  expect_eq "publish.yml: the publish job runs in the 'release' environment (lock 2) and needs the build job" 2 "$([ "$(printf '%s\n' "$PP" | grep -cE '^    environment: release$')" = 1 ] && [ "$(printf '%s\n' "$PP" | grep -cE '^    needs: build$')" = 1 ] && echo 2 || echo 0)"
  expect_eq "publish.yml: the build job has no environment and no secrets" 0 "$(printf '%s\n' "$PB" | grep -cE 'environment:|secrets\.')"
  # permissions: contents: read on build; id-token and attestations only on publish
  expect_eq "publish.yml: build has contents: read and nothing else" "contents: read" "$(printf '%s\n' "$PB" | awk '/^    permissions:/{p=1; next} p && /^      /{gsub(/^ +/,""); print; next} p{exit}' | tr '\n' ' ' | sed 's/ $//')"
  expect_eq "publish.yml: publish has contents: read, id-token: write and attestations: write" "contents: read id-token: write attestations: write" "$(printf '%s\n' "$PP" | awk '/^    permissions:/{p=1; next} p && /^      /{gsub(/^ +/,""); print; next} p{exit}' | tr '\n' ' ' | sed 's/ $//')"
  expect_eq "publish.yml: id-token and attestations appear nowhere in the build job" 0 "$(printf '%s\n' "$PB" | grep -cE 'id-token|attestations')"
  # build job rules
  expect_eq "publish.yml: build covers ubuntu, macos and windows, fail-fast false, same exact Pythons as the rehearsal" "$(printf '%s\n' "${WPINS:-}" | sort)" "$(printf '%s\n' "$PB" | py_pins | sort)"
  expect_eq "publish.yml: build matrix covers ubuntu, macos and windows" 1 "$(printf '%s\n' "$PB" | grep -cE 'os: \[ubuntu-latest, windows-latest, macos-latest\]')"
  expect_eq "publish.yml: build runs every step in bash (defaults.run.shell: bash at the top)" 1 "$(printf '%s\n' "$PC" | awk '/^defaults:/{d=1; next} d && /^[^ ]/{exit} d{print}' | grep -cE '^    shell: bash$')"
  expect_eq "publish.yml: tools by hash (--require-hashes --no-deps --only-binary=:all:), wasm tools from the digest-pinned installer" 1 "$([ "$(printf '%s\n' "$PB" | grep -E 'pip install' | grep -F -- '--require-hashes' | grep -F -- '--no-deps' | grep -cF -- '--only-binary=:all:')" -ge 1 ] && [ "$(printf '%s\n' "$PB" | grep -cF 'scripts/install-wasm-tools.sh')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "publish.yml: no cache of any kind in either job" 0 "$(printf '%s\n%s\n' "$PB" "$PP" | grep -cE 'actions/cache|Swatinem/rust-cache|^[[:space:]]*cache:')"
  expect_eq "publish.yml: no test-key string anywhere (allowTestKeys, --allow-test-key, --trust-test-key, rfc8032, --test-key)" 0 "$(printf '%s\n' "$PC" | grep -ciE 'allowtestkeys|--allow-test-key|--trust-test-key|rfc8032|--test-key')"
  expect_eq "publish.yml: no \${{ }} expression inside a run: step in either job" 0 "$(printf '%s\n' "$PC" | awk '/^[[:space:]]*(- )?run:/{ind=match($0,/[^ ]/); if ($0 ~ /run:[[:space:]]*[|>]/) {inblk=1; blkind=ind; next} else {print; next}} inblk{ if ($0 ~ /^[[:space:]]*$/) next; cur=match($0,/[^ ]/); if (cur>blkind+1) {print; next} else {inblk=0} }' | grep -c '\${{')"
  expect_eq "publish.yml: every checkout has persist-credentials: false" "$(printf '%s\n' "$PC" | grep -c 'actions/checkout@')" "$(printf '%s\n' "$PC" | grep -c 'persist-credentials: false')"
  expect_eq "publish.yml: the build job uploads one candidate per OS: 1 day, if-no-files-found: error, hidden files off" 1 "$([ "$(printf '%s\n' "$PB" | grep -cE 'actions/upload-artifact@')" = 1 ] && [ "$(printf '%s\n' "$PB" | grep -cE '^[[:space:]]*retention-days: 1$')" = 1 ] && [ "$(printf '%s\n' "$PB" | grep -cE '^[[:space:]]*if-no-files-found: error$')" = 1 ] && [ "$(printf '%s\n' "$PB" | grep -cE '^[[:space:]]*include-hidden-files: false$')" = 1 ] && echo 1 || echo 0)"
  expect_eq "publish.yml: the candidate artefact name carries the OS" 1 "$(printf '%s\n' "$PB" | grep -cF 'name: pagetriage-candidate-${{ matrix.os }}')"
  # lock 6, bindings, verification: present in the publish job, in this order, before attestation and the first publish step
  order() { # order <pattern>...: the line numbers of the first match of each pattern in the publish job, true when strictly increasing
    local last=0 n p
    for p in "$@"; do n=$(printf '%s\n' "$PP" | grep -nE -- "$p" | head -1 | cut -d: -f1); [ -n "$n" ] && [ "$n" -gt "$last" ] || { echo "no"; return; }; last=$n; done; echo yes
  }
  expect_eq "publish.yml: lock 6 (publish-guard.sh key-id with RELEASE_KEY_ID from vars) comes straight after lock 3 (armed)" yes "$(order 'publish-guard.sh armed' 'RELEASE_KEY_ID: \${{ vars.RELEASE_KEY_ID }}' 'publish-guard.sh key-id')"
  expect_eq "publish.yml: order: armed, key id, version, tag binding, registry absent, download, signed manifest, verify --expect-id --trust-file, manifest binding, exact set, attestation, crates (package, digests, publish, index), npm, PyPI" yes "$(order 'publish-guard.sh armed' 'publish-guard.sh key-id' 'publish-guard.sh version' 'publish-guard.sh tag-binding' 'publish-guard.sh registry-absent' 'actions/download-artifact@' 'gh release download' 'release-tool.mjs verify' 'publish-guard.sh manifest-binding' 'publish-guard.sh exact-set' 'actions/attest-build-provenance@' 'cargo package --locked --no-verify' 'publish-guard.sh crate-digests' 'cargo publish --locked --no-verify' 'publish-guard.sh index-check' 'npm publish' 'pypa/gh-action-pypi-publish@')"
  # S1-131: the crate steps are four consecutive steps, before the PyPI step (a Docker action that runs as root must not touch the tree between
  # the digest comparison and `cargo publish`; a failure there must leave nothing published on PyPI)
  stepno() { printf '%s\n' "$PP" | awk -v p="$1" '/^      - /{c++} $0 ~ p && !f {print c; f=1}'; }
  N_PKG=$(stepno 'cargo package --locked'); N_DIG=$(stepno 'publish-guard.sh crate-digests'); N_PUB=$(stepno 'cargo publish --locked'); N_IDX=$(stepno 'publish-guard.sh index-check'); N_PYPI=$(stepno 'pypa/gh-action-pypi-publish@')
  expect_eq "publish.yml: re-package, digest comparison, cargo publish and the index check are four consecutive steps" "$((N_PKG+1)) $((N_PKG+2)) $((N_PKG+3))" "${N_DIG:-x} ${N_PUB:-x} ${N_IDX:-x}"
  expect_eq "publish.yml: the crate steps come before the PyPI step (S1-131)" 1 "$([ -n "$N_IDX" ] && [ -n "$N_PYPI" ] && [ "$N_IDX" -lt "$N_PYPI" ] && echo 1 || echo 0)"
  expect_eq "publish.yml: cargo package and cargo publish both say --locked --no-verify -p pagetriage-core -p pagetriage-cli (verification already ran in build and in the rehearsal), once each" 2 "$([ "$(printf '%s\n' "$PP" | grep -cE 'cargo package --locked --no-verify -p pagetriage-core -p pagetriage-cli$')" = 1 ] && [ "$(printf '%s\n' "$PP" | grep -cE 'cargo publish --locked --no-verify -p pagetriage-core -p pagetriage-cli$')" = 1 ] && echo 2 || echo 0)"
  expect_eq "publish.yml: every cargo package and cargo publish line in the file is --locked --no-verify" 0 "$(printf '%s\n' "$PC" | grep -E '(^|[^A-Za-z_-])cargo (package|publish)( |$)' | grep -vcE -- '--locked --no-verify')"
  expect_eq "publish.yml: the post-publish index check reads the crates.io sparse index through the guard, after cargo publish, with no \${{ }} in it" 1 "$([ -n "$N_IDX" ] && [ -n "$N_PUB" ] && [ "$N_IDX" -gt "$N_PUB" ] && [ "$(step_n "$N_IDX" | grep -cE '^        run: .*publish-guard\.sh index-check verified')" = 1 ] && [ "$(step_n "$N_IDX" | grep -c '\${{')" = 0 ] && echo 1 || echo 0)"
  expect_eq "publish.yml: the release manifest is verified with --expect-id pagetriage-release and --trust-file docs/release-keys.json" 1 "$(printf '%s\n' "$PP" | grep -F 'release-tool.mjs verify' | grep -F -- '--expect-id pagetriage-release' | grep -cF -- '--trust-file docs/release-keys.json')"
  expect_eq "publish.yml: the tag binding gets GUARD_REPO, GUARD_SHA from github.sha and a GH_TOKEN of github.token" 1 "$(printf '%s\n' "$PP" | awk '/Binding 1/{b=1} b' | head -8 | grep -cE 'GUARD_SHA: \${{ github.sha }}|GH_TOKEN: \${{ github.token }}|GUARD_REPO: \${{ github.repository }}' | awk '{print ($1==3)?1:0}')"
  expect_eq "publish.yml: download-artifact has no run-id and no github-token input (this run only)" 0 "$(printf '%s\n' "$PP" | awk '/actions\/download-artifact@/{d=1; next} d && /^      - /{d=0} d{print}' | grep -cE 'run-id|github-token|repository:')"
  expect_eq "publish.yml: the candidates are downloaded by pattern pagetriage-candidate-* with merge-multiple" 1 "$(printf '%s\n' "$PP" | awk '/actions\/download-artifact@/{d=1; next} d && /^      - /{d=0} d{print}' | grep -cE 'pattern: pagetriage-candidate-\*|merge-multiple: true' | awk '{print ($1==2)?1:0}')"
  expect_eq "publish.yml: the exact paths come from the exact-set lists, with no glob in a publish or attestation step" 0 "$(printf '%s\n' "$PP" | grep -E 'npm publish|cargo publish|subject-path|packages-dir|cp verified' | grep -cE '\*')"
  expect_eq "publish.yml: attestation is after verification, with subject-path from the exact list" 1 "$(printf '%s\n' "$PP" | grep -cE 'subject-path: \${{ steps\.exact\.outputs\.paths }}')"
  # publishing steps and secrets
  expect_eq "publish.yml: npm publish has --provenance --access public --ignore-scripts and a derived --tag" 1 "$(printf '%s\n' "$PP" | grep -F 'npm publish' | grep -F -- '--provenance' | grep -F -- '--access public' | grep -F -- '--ignore-scripts' | grep -cF -- '--tag "$DIST_TAG"')"
  expect_eq "publish.yml: npm publish names a ./ path (npm reads 'dir/file.tgz' as a GitHub owner/repo shorthand and runs git ls-remote)" 1 "$(printf '%s\n' "$PP" | grep -F 'npm publish' | grep -cF 'npm publish "./verified/')"
  expect_eq "publish.yml: the dist-tag is derived by the guard from the version read at this commit" 1 "$([ "$(printf '%s\n' "$PP" | grep -cF 'publish-guard.sh dist-tag')" = 1 ] && [ "$(printf '%s\n' "$PP" | grep -cF 'publish-guard.sh version')" = 1 ] && echo 1 || echo 0)"
  expect_eq "publish.yml: PyPI through pypa/gh-action-pypi-publish with attestations: true and packages-dir" 1 "$(printf '%s\n' "$PP" | awk '/pypa\/gh-action-pypi-publish@/{d=1; next} d && /^      - /{d=0} d{print}' | grep -cE 'attestations: true|packages-dir: pypi-dist/' | awk '{print ($1==2)?1:0}')"
  expect_eq "publish.yml: no PyPI token anywhere (trusted publishing)" 0 "$(printf '%s\n' "$PC" | grep -ciE 'pypi_token|PYPI_API|password:|twine')"
  expect_eq "publish.yml: NPM_TOKEN and CARGO_REGISTRY_TOKEN appear only in a publish-job step env (once each)" 2 "$([ "$(printf '%s\n' "$PP" | grep -cE 'secrets\.NPM_TOKEN')" = 1 ] && [ "$(printf '%s\n' "$PP" | grep -cE 'secrets\.CARGO_REGISTRY_TOKEN')" = 1 ] && [ "$(printf '%s\n' "$PB" | grep -cE 'secrets\.')" = 0 ] && echo 2 || echo 0)"
  expect_eq "publish.yml: each token line sits under an env: key of a step, never in run:" 2 "$(printf '%s\n' "$PP" | awk '/^        env:/{e=1; next} /^        run:/{e=0} /^      - /{e=0} e && /secrets\./{c++} END{print c+0}')"
  expect_eq "publish.yml: an announcement of the checks: the build prints the candidate digests for the owner" 1 "$([ "$(printf '%s\n' "$PB" | grep -cE 'candidate digests')" -ge 1 ] && echo 1 || echo 0)"
  # FR2 (BUG-T3-S7-19): no step of publish.yml may be made optional or conditional, and both jobs have a timeout
  expect_eq "publish.yml: no continue-on-error anywhere (a failed lock or binding must fail the job)" 0 "$(printf '%s\n' "$PC" | grep -c 'continue-on-error')"
  expect_eq "publish.yml: no step-level if: in the publish job (job-level guards only; always() would run a step after a failed check)" 0 "$(printf '%s\n' "$PP" | grep -cE '^      +(- )?if:|^        if:')"
  expect_eq "publish.yml: the only step-level if: in the build job is the Linux-only wasm tools step, exactly" "        if: matrix.os == 'ubuntu-latest'" "$(printf '%s\n' "$PB" | grep -E '^        if:')"
  expect_eq "publish.yml: no if: mentions always(), failure(), cancelled() or success() anywhere" 0 "$(printf '%s\n' "$PC" | grep -cE '(always|failure|cancelled|success)\(\)')"
  expect_eq "publish.yml: the build job has timeout-minutes: 75 and the publish job timeout-minutes: 30" 1 "$([ "$(printf '%s\n' "$PB" | grep -cE '^    timeout-minutes: 75$')" = 1 ] && [ "$(printf '%s\n' "$PP" | grep -cE '^    timeout-minutes: 30$')" = 1 ] && echo 1 || echo 0)"
fi
# ---- G. scripts/release/publish-dry-run.sh ------------------------------------------------------------
echo "== G. publish-dry-run.sh: every publish command is a dry run; no token; the checks the publish job relies on"
DRY=$REPO/scripts/release/publish-dry-run.sh
if [ ! -f "$DRY" ]; then fail "scripts/release/publish-dry-run.sh exists"; else
  ok "scripts/release/publish-dry-run.sh exists"
  DC=$(nocomments < "$DRY")
  expect_eq "dry run: every npm publish and cargo publish line says --dry-run (no real publish is reachable)" 0 "$(printf '%s\n' "$DC" | grep -E '(^|[^A-Za-z_-])(npm|cargo) publish' | grep -vE '^[[:space:]]*(echo|printf|die|log)|die "|echo "|printf ' | grep -vc -- '--dry-run')"
  expect_eq "dry run: npm publish --dry-run has --ignore-scripts and --access public and the derived --tag" 1 "$(printf '%s\n' "$DC" | grep -F 'npm publish' | grep -F -- '--dry-run' | grep -F -- '--ignore-scripts' | grep -F -- '--access public' | grep -cF -- '--tag')"
  expect_eq "dry run: cargo publish --dry-run --locked --no-verify names the two crates (the publish job's flags)" 1 "$(printf '%s\n' "$DC" | grep -F 'cargo publish' | grep -F -- '--dry-run' | grep -F -- '--locked' | grep -F -- '--no-verify' | grep -cF -- '-p pagetriage-core -p pagetriage-cli')"
  expect_eq "dry run: it runs the publish job's package command (cargo package --locked --no-verify -p pagetriage-core -p pagetriage-cli) and compares the crates with those of the rehearsal (S1-131)" 1 "$([ "$(printf '%s\n' "$DC" | grep -cE 'cargo package --locked --no-verify .*-p pagetriage-core -p pagetriage-cli')" -ge 1 ] && [ "$(printf '%s\n' "$DC" | grep -cF 'publish-guard.sh crate-digests')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "dry run: no verify switch (the same command as the publish job, never a different one)" 0 "$(printf '%s\n' "$DC" | grep -c 'PUBLISH_DRY_RUN_VERIFY')"
  expect_eq "dry run: the wheel check (tests/python/check_wheel.py) runs on every wheel, and the dist-tag comes from publish-guard.sh" 1 "$([ "$(printf '%s\n' "$DC" | grep -cF 'tests/python/check_wheel.py')" -ge 1 ] && [ "$(printf '%s\n' "$DC" | grep -cF 'publish-guard.sh dist-tag')" -ge 1 ] && echo 1 || echo 0)"
  expect_eq "dry run: no token, no provenance flag (needs OIDC), no secret and no registry credential is set" 0 "$(printf '%s\n' "$DC" | grep -vE '^[[:space:]]*(log|echo|die) |die "|log "|echo "' | grep -cE 'NODE_AUTH_TOKEN=|NPM_TOKEN=|CARGO_REGISTRY_TOKEN=|secrets\.|--provenance|npm login|cargo login|twine')"
  expect_eq "dry run: the credentials that could exist in a runner's environment are removed before each publish command runs" 1 "$([ "$(printf '%s\n' "$DC" | grep -E '(npm|cargo) publish' | grep -cE 'env -u NODE_AUTH_TOKEN -u NPM_TOKEN -u CARGO_REGISTRY_TOKEN')" -ge 2 ] && echo 1 || echo 0)"
fi
# ---- H. the toolchain steps install everything rust-toolchain.toml lists (run 44651022212) ------------------------
# rust-toolchain.toml makes every `cargo` call in a checkout ensure its channel, components and targets. A dtolnay/rust-toolchain
# step that installs less leaves the first `cargo` call to top the toolchain up through rustup's IMPLICIT install, and that path is not
# process-safe (rust-lang/rustup#988): it died with "failed to install component: 'clippy-preview-...', detected conflict:
# 'bin/cargo-clippy'" on ubuntu-latest and macos-latest in release-rehearsal, at the first cargo call of the build step, while the
# same step passed on Windows. A toolchain that is complete before the first cargo call has nothing left to install.
echo "== H. every dtolnay/rust-toolchain step installs the channel, components and targets of rust-toolchain.toml (no implicit rustup install at the first cargo call)"
TCF=${TOOLCHAIN_FILE:-$REPO/rust-toolchain.toml}
if [ ! -f "$TCF" ]; then fail "rust-toolchain.toml exists"; else
  # tc_norm: a TOML scalar or array, or a workflow `with:` value, as a sorted space-separated set without quotes or brackets
  tc_norm() { tr -d '"[]' | tr ', ' '\n\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//'; }
  tc_key() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$TCF" | head -1 | tc_norm; }
  WANT_CH=$(tc_key channel); WANT_CO=$(tc_key components); WANT_TA=$(tc_key targets)
  [ -n "$WANT_CH" ] && ok "rust-toolchain.toml names channel '$WANT_CH', components '$WANT_CO', targets '$WANT_TA'" || fail "rust-toolchain.toml has a channel"
  # one line per dtolnay step of the workflow file $1: <file>|<toolchain>|<components>|<targets>, '-' where the step does not set the input
  # (END, not gawk's ENDFILE: the awk of macOS has none)
  rt_steps() { awk '
    function flush() { if (on) { n = split(FILENAME, a, "/"); printf "%s|%s|%s|%s\n", a[n], tc, co, ta }; on = 0 }
    /^[[:space:]]*#/ { next }
    { match($0, /^ */); ind = RLENGTH }
    /uses:[[:space:]]*dtolnay\/rust-toolchain@/ { flush(); on = 1; tc = "-"; co = "-"; ta = "-"; next }
    on && NF && ind <= 6 { flush() }
    on && /^ +toolchain:/ { v = $0; sub(/^ +toolchain:[[:space:]]*/, "", v); tc = v; next }
    on && /^ +components:/ { v = $0; sub(/^ +components:[[:space:]]*/, "", v); co = v; next }
    on && /^ +targets:/ { v = $0; sub(/^ +targets:[[:space:]]*/, "", v); ta = v; next }
    END { flush() }
  ' "$1"; }
  NSTEPS=0; BADTC=0
  while IFS='|' read -r f tc co ta; do
    NSTEPS=$((NSTEPS+1))
    [ "$co" = - ] && co=""; [ "$ta" = - ] && ta=""; [ "$tc" = - ] && tc=""
    gc=$(printf '%s' "$tc" | tc_norm); go=$(printf '%s' "$co" | tc_norm); gt=$(printf '%s' "$ta" | tc_norm)
    if [ "$gc" != "$WANT_CH" ] || [ "$go" != "$WANT_CO" ] || [ "$gt" != "$WANT_TA" ]; then
      echo "  $f, dtolnay step $NSTEPS: toolchain '$gc', components '$go', targets '$gt' (rust-toolchain.toml: '$WANT_CH', '$WANT_CO', '$WANT_TA')"; BADTC=$((BADTC+1)); fi
  done < <(for wf in "$WF"/*.yml; do rt_steps "$wf"; done)
  if [ "$NSTEPS" -ge 1 ]; then ok "found $NSTEPS dtolnay/rust-toolchain steps"; else fail "at least one dtolnay/rust-toolchain step is found in the workflows"; fi
  expect_eq "every dtolnay/rust-toolchain step sets toolchain, components and targets to what rust-toolchain.toml lists (an incomplete toolchain starts a rustup implicit install at the first cargo call)" 0 "$BADTC"
fi

finish
