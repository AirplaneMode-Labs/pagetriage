#!/usr/bin/env bash
# Sprint 7 (D2-02, D2-03): tests/scripts/ci-policy.sh is only worth its green if it goes RED when a workflow rule is broken. This file copies
# the workflows to a scratch directory, breaks one rule at a time (a mutation), runs ci-policy.sh against the copy (WF=<scratch>) and expects a
# failure; a control run on an unmutated copy must pass. A mutation that the policy does not catch is a hole in the policy.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
fresh() { rm -rf "$S/wf"; mkdir -p "$S/wf"; cp "$REPO"/.github/workflows/*.yml "$S/wf/"; }
policy_rc() { WF="$S/wf" bash "$REPO/tests/scripts/ci-policy.sh" > "$S/out.txt" 2>&1; echo $?; }
# mutate <name> <file> <python expression on s>: apply the edit (must change the file), run the policy, expect exit 1
mutate() {
  local name=$1 file=$2 expr=$3
  fresh
  if ! MUT_FILE="$S/wf/$file" MUT_EXPR="$expr" python3 -I - <<'PY'
import os, sys
p = os.environ["MUT_FILE"]; s = open(p).read(); t = eval(os.environ["MUT_EXPR"], {"s": s})
if t == s: print("the mutation changed nothing", file=sys.stderr); sys.exit(3)
open(p, "w").write(t)
PY
  then fail "mutation '$name' could not be applied"; return; fi
  if [ "$(policy_rc)" = 1 ]; then ok "red on: $name ($(grep -m1 '^FAIL' "$S/out.txt" | cut -c1-110))"; else fail "the policy stayed green on: $name"; fi
}
fresh
expect_eq "control: the unmutated workflows pass the policy" 0 "$(policy_rc)"

P=publish.yml
mutate "publish: a push trigger" $P 's.replace("on:\n  workflow_dispatch:\n", "on:\n  push:\n    branches: [main]\n  workflow_dispatch:\n")'
mutate "publish: a pull_request trigger" $P 's.replace("on:\n  workflow_dispatch:\n", "on:\n  pull_request:\n  workflow_dispatch:\n")'
mutate "publish: a workflow_dispatch input" $P 's.replace("  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      go:\n        type: string\n",1)'
mutate "publish: permissions left at the default" $P 's.replace("permissions: {}\n", "permissions:\n  contents: write\n",1)'
mutate "publish: the release environment removed" $P 's.replace("    environment: release\n", "")'
# TD-125 (lock 3): the variable is read in a step, never in a job-level if
mutate "publish: vars.RELEASE_PUBLISH_ARMED back in the publish job's if (an environment variable is invisible there)" $P 's.replace("    if: github.repository == '"'"'AirplaneMode-Labs/pagetriage'"'"' && github.ref == '"'"'refs/heads/main'"'"'\n    runs-on: ubuntu-latest\n    environment: release", "    if: github.repository == '"'"'AirplaneMode-Labs/pagetriage'"'"' && github.ref == '"'"'refs/heads/main'"'"' && vars.RELEASE_PUBLISH_ARMED == '"'"'true'"'"'\n    runs-on: ubuntu-latest\n    environment: release")'
mutate "publish: a vars. read in the build job's if" $P 's.replace("    if: github.repository == '"'"'AirplaneMode-Labs/pagetriage'"'"' && github.ref == '"'"'refs/heads/main'"'"'\n    runs-on: ${{ matrix.os }}", "    if: github.repository == '"'"'AirplaneMode-Labs/pagetriage'"'"' && github.ref == '"'"'refs/heads/main'"'"' && vars.SOMETHING == '"'"'x'"'"'\n    runs-on: ${{ matrix.os }}",1)'
mutate "publish: the armed step removed (lock 3 is not checked anywhere)" $P 's.replace("run: bash scripts/release/publish-guard.sh armed", "run: true")'
mutate "publish: the armed step's ARMED env removed" $P 's.replace("        env:\n          ARMED: ${{ vars.RELEASE_PUBLISH_ARMED }}\n        run: bash scripts/release/publish-guard.sh armed", "        run: bash scripts/release/publish-guard.sh armed")'
mutate "publish: the armed step moved after the toolchain step (not first after the checkout)" $P '(lambda a, b: s[:a] + s[b:b + s[b:].index("      - uses: actions/setup-node")] + s[a:b] + s[b + s[b:].index("      - uses: actions/setup-node"):])(s.index("      - name: Lock 3"), s.index("      - uses: dtolnay/rust-toolchain", s.index("      - name: Lock 3")))'
mutate "publish: RELEASE_PUBLISH_ARMED read a second time in a step env" $P 's.replace("          RELEASE_KEY_ID: ${{ vars.RELEASE_KEY_ID }}\n", "          RELEASE_KEY_ID: ${{ vars.RELEASE_KEY_ID }}\n          ALSO: ${{ vars.RELEASE_PUBLISH_ARMED }}\n")'
# S1-131: the crate steps
mutate "publish: cargo package without --no-verify" $P 's.replace("cargo package --locked --no-verify -p pagetriage-core -p pagetriage-cli", "cargo package --locked -p pagetriage-core -p pagetriage-cli")'
mutate "publish: cargo publish without --no-verify" $P 's.replace("cargo publish --locked --no-verify -p pagetriage-core -p pagetriage-cli", "cargo publish --locked -p pagetriage-core -p pagetriage-cli")'
mutate "publish: the crate steps moved after the PyPI step" $P '(lambda a, b: s[:a] + s[b:] + s[a:b])(s.index("      - name: Crates 1 of 4"), s.index("      - name: Publish the npm package"))'
mutate "publish: the post-publish crates.io index check removed" $P 's.replace("publish-guard.sh index-check verified", "true")'
mutate "publish: a step between the digest comparison and cargo publish" $P 's.replace("      - name: Crates 3 of 4", "      - name: Something else\n        run: true\n      - name: Crates 3 of 4")'
mutate "publish: the index check moved before cargo publish" $P '(lambda a, b, c: s[:a] + s[b:c] + s[a:b] + s[c:])(s.index("      - name: Crates 3 of 4"), s.index("      - name: Crates 4 of 4"), s.index("      - name: Publish the npm package"))'

mutate "publish: the main-branch guard removed from the build job" $P 's.replace("    if: github.repository == '"'"'AirplaneMode-Labs/pagetriage'"'"' && github.ref == '"'"'refs/heads/main'"'"'\n    runs-on: ${{ matrix.os }}", "    runs-on: ${{ matrix.os }}",1)'
mutate "publish: id-token in the build job" $P 's.replace("    timeout-minutes: 75\n    permissions:\n      contents: read\n", "    timeout-minutes: 75\n    permissions:\n      contents: read\n      id-token: write\n",1)'
mutate "publish: attestations missing from the publish job" $P 's.replace("      attestations: write\n", "")'
mutate "publish: lock 6 (the key id check) removed" $P 's.replace("bash scripts/release/publish-guard.sh key-id", "true")'
mutate "publish: the registry-absent check removed" $P 's.replace("bash scripts/release/publish-guard.sh registry-absent", "true")'
mutate "publish: the tag binding removed" $P 's.replace("bash scripts/release/publish-guard.sh tag-binding", "true")'
mutate "publish: verification without --expect-id" $P 's.replace(" --expect-id pagetriage-release --trust-file docs/release-keys.json", " --trust-file docs/release-keys.json")'
mutate "publish: verification with the test key" $P 's.replace("--trust-file docs/release-keys.json", "--trust-test-key --allow-test-key")'
mutate "publish: attestation moved after npm publish (provenance must come first)" $P 's.replace("      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2\n        with:\n          subject-path: ${{ steps.exact.outputs.paths }}\n", "")+"      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2\n        with:\n          subject-path: ${{ steps.exact.outputs.paths }}\n"'
mutate "publish: npm publish without --provenance" $P 's.replace(" --provenance", "")'
mutate "publish: npm publish without --ignore-scripts" $P 's.replace(" --ignore-scripts --tag", " --tag")'
mutate "publish: PyPI without attestations: true" $P 's.replace("          attestations: true\n", "")'
mutate "publish: a PyPI token" $P 's.replace("          attestations: true\n", "          attestations: true\n          password: ${{ secrets.PYPI_TOKEN }}\n")'
mutate "publish: npm publish of a bare dir/file path (git shorthand)" $P 's.replace("npm publish \"./verified/", "npm publish \"verified/")'
mutate "publish: a glob in a publish path" $P 's.replace("npm publish \"./verified/$(cat lists/npm.txt)\"", "npm publish verified/*.tgz")'
mutate "publish: download from another run (run-id)" $P 's.replace("          merge-multiple: true\n", "          merge-multiple: true\n          run-id: 123\n")'
mutate "publish: a cache in the build job" $P 's.replace("          python-version: ${{ matrix.python }}\n", "          python-version: ${{ matrix.python }}\n          cache: pip\n")'
mutate "publish: candidate retention of 14 days" $P 's.replace("          retention-days: 1\n", "          retention-days: 14\n")'
mutate "publish: upload without if-no-files-found: error" $P 's.replace("          if-no-files-found: error\n", "")'
mutate "publish: a token in a run step" $P 's.replace("        run: cargo publish --locked --no-verify -p pagetriage-core -p pagetriage-cli", "        run: CARGO_REGISTRY_TOKEN=${{ secrets.CARGO_REGISTRY_TOKEN }} cargo publish --locked --no-verify -p pagetriage-core -p pagetriage-cli")'
mutate "publish: another secret" $P 's.replace("secrets.NPM_TOKEN", "secrets.GITHUB_TOKEN")'
mutate "publish: a checkout that keeps credentials" $P 's.replace("          persist-credentials: false\n", "",1)'
mutate "publish: an action by tag instead of SHA" $P 's.replace("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1", "actions/checkout@v4",1)'
mutate "publish: an action SHA that is not in the table" $P 's.replace("pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086", "pypa/gh-action-pypi-publish@0000000000000000000000000000000000000000")'
mutate "publish: pull_request_target" $P 's.replace("on:\n  workflow_dispatch:\n", "on:\n  pull_request_target:\n  workflow_dispatch:\n")'
mutate "publish: crates published without the digest comparison" $P 's.replace("crate-digests verified target/package", "true")'
# FR2 (BUG-T3-S7-19): T3's five survivors plus a removed publish timeout
cont() { echo 's.replace("      - name: '"$1"'\n", "      - name: '"$1"'\n        continue-on-error: true\n",1)'; }
alw() { echo 's.replace("      - name: '"$1"'\n", "      - name: '"$1"'\n        if: always()\n",1)'; }
mutate "publish: continue-on-error on the Lock 4 verify step" $P "$(cont 'Lock 4, verify the signed manifest against docs/release-keys.json')"
mutate "publish: continue-on-error on Binding 1" $P "$(cont 'Binding 1, tag v<version> peels to this commit')"
mutate "publish: if: always() on the npm publish step" $P "$(alw 'Publish the npm package (provenance, public, no install scripts, a derived dist-tag)')"
mutate "publish: if: always() on Crates 3 of 4" $P "$(alw 'Crates 3 of 4, publish the crates (core, then cli, in one invocation; the publish = false crates are not named)')"
mutate "publish: if: always() on the PyPI staging step" $P "$(alw 'Stage exactly the PyPI files (the sdist and the three wheels)')"
mutate "publish: the publish job's timeout removed" $P 's.replace("    timeout-minutes: 30\n", "",1)'
mutate "publish: the build job's timeout removed" $P 's.replace("    timeout-minutes: 75\n", "",1)'
mutate "stats: an upload without include-hidden-files: false" stats.yml 's.replace("          include-hidden-files: false\n", "")'
mutate "publish: a third job" $P 's+"\n  extra:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n    steps:\n      - run: true\n"'

C=ci.yml
mutate "ci: Swatinem/rust-cache in release-rehearsal" $C 's.replace("          persist-credentials: false\n      # The toolchain is complete before the first cargo call", "          persist-credentials: false\n      - uses: Swatinem/rust-cache@d1527c8f67ef9af357290475d4af4b0fab8f12e0 # v2.9.3\n      # The toolchain is complete before the first cargo call", 1)'
mutate "ci: release-rehearsal artefact kept 14 days" $C 's.replace("          retention-days: 3\n", "          retention-days: 14\n")'
mutate "ci: release-rehearsal artefact with hidden files included" $C 's.replace("          include-hidden-files: false\n", "")'
mutate "ci: release-rehearsal artefact path adds the build tree" $C 's.replace("            dist-release-report/\n", "            dist-release-report/\n            target/\n")'
mutate "ci: release-rehearsal artefact not named as a rehearsal" $C 's.replace("REHEARSAL-test-key-NOT-A-RELEASE-pagetriage-", "pagetriage-")'
mutate "ci: release-rehearsal with a plain pip install" $C 's.replace("          \"$TOOLS_BIN/python\" -m pip install --require-hashes --no-deps --only-binary=:all: -r tools/ci/requirements.txt\n          \"$TOOLS_BIN/maturin\" --version\n      - name: Install pinned wasm-bindgen CLI and wasm-opt (digest-pinned release binaries)", "          \"$TOOLS_BIN/python\" -m pip install maturin\n          \"$TOOLS_BIN/maturin\" --version\n      - name: Install pinned wasm-bindgen CLI and wasm-opt (digest-pinned release binaries)",1)'
mutate "ci: release-rehearsal granting id-token" $C 's.replace("    timeout-minutes: 75\n    permissions:\n      contents: read\n", "    timeout-minutes: 75\n    permissions:\n      contents: read\n      id-token: write\n",1)'
mutate "ci: the sign step dropped from release-rehearsal" $C 's.replace("bash scripts/release/rehearse.sh sign", "true")'
mutate "ci: a version interpolated into a run step" $C 's.replace("run: bash scripts/release/rehearse.sh gate", "run: echo ${{ matrix.os }} && bash scripts/release/rehearse.sh gate")'
mutate "ci: a secret in ci.yml" $C 's.replace("      TOOLS_BIN: ${{ matrix.os", "      TOKEN: ${{ secrets.X }}\n      TOOLS_BIN: ${{ matrix.os",1)'
mutate "ci: the Linux Python pin in release-rehearsal differs from the determinism job" $C 's.replace("            python: \"3.12.16\"\n          - os: macos-latest\n            python: \"3.12.10\"\n          - os: windows-latest\n            python: \"3.12.10\"\n    env:\n      TOOLS_BIN", "            python: \"3.12.15\"\n          - os: macos-latest\n            python: \"3.12.10\"\n          - os: windows-latest\n            python: \"3.12.10\"\n    env:\n      TOOLS_BIN",1)'
# run 44651022212 (check H): a toolchain step that installs less than rust-toolchain.toml lists leaves the first cargo call to a rustup implicit install
mutate "ci: release-rehearsal toolchain step without components (the first cargo call would top the toolchain up through rustup)" $C 's.replace("          components: rustfmt, clippy\n          targets: wasm32-unknown-unknown\n      - uses: actions/setup-python", "          targets: wasm32-unknown-unknown\n      - uses: actions/setup-python", 1)'
mutate "ci: release-rehearsal toolchain step without the wasm32 target" $C 's.replace("          components: rustfmt, clippy\n          targets: wasm32-unknown-unknown\n      - uses: actions/setup-python", "          components: rustfmt, clippy\n      - uses: actions/setup-python", 1)'
mutate "ci: the cargo-deny toolchain step without components" $C 's.replace("          components: rustfmt, clippy\n          targets: wasm32-unknown-unknown\n      - name: cargo-deny", "          targets: wasm32-unknown-unknown\n      - name: cargo-deny", 1)'
mutate "publish: the publish job's toolchain step without components" $P 's.replace("          components: rustfmt, clippy\n          targets: wasm32-unknown-unknown\n      - uses: actions/setup-node", "          targets: wasm32-unknown-unknown\n      - uses: actions/setup-node", 1)'
mutate "publish: a toolchain step on another channel than rust-toolchain.toml" $P 's.replace("          toolchain: \"1.98\"\n", "          toolchain: \"1.99\"\n", 1)'
finish
