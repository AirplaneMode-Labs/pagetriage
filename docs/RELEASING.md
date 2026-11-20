# Releasing pagetriage 1.0.0: the owner's steps

Nothing in this repository publishes by itself, and nobody on the team will run a publish, tag a commit, reserve a name, create a key or change a GitHub
setting. This page lists, in order, what is left for the owner and nothing the team could have done itself. The team's side is finished and checked:

- **The artefacts build as a release builds them** (`scripts/release/build-artefacts.sh`): the npm tarball `@airplanemode/pagetriage` (the PDF-enabled WebAssembly build), a wheel for each of three
  platforms, the source package (sdist) and the two packaged crates `pagetriage-core` and `pagetriage-cli`.
- **The CI job `release-rehearsal (<os>)`** (Linux, macOS, Windows; [release.md](release.md), "Sprint 7: what only CI can prove") installs each built file into a fresh place
  and makes one real call, builds the command-line tool from the packaged crates with no registry in reach, then signs a `pagetriage-rehearsal` manifest with the published RFC 8032 test key,
  verifies it with the explicit flag, and shows the refusals. It is a rehearsal: the test key can never sign a `-release` id and is refused everywhere else.
- **`.github/workflows/publish.yml`** exists and cannot fire by accident: `workflow_dispatch` only, main of this repository only, six locks, three bindings, provenance, then publishing from the exact
  files the verified manifest lists (the crates first, as four steps in a row, then npm, then PyPI). Its checks are in `scripts/release/publish-guard.sh` and each refusal is tested (`tests/scripts/publish-guard.sh`); the workflow's own rules are
  tested too (`tests/scripts/ci-policy.sh`, `tests/scripts/ci-policy-mutations.sh`). The release is armed by one variable of the `release` environment (step 15); the job's first step after the checkout refuses unless it reads `true`,
  because a variable of an environment cannot be read in a job-level `if`. No one has run the workflow.
- **`docs/release-keys.json`** is committed with no key in it, so today nothing verifies: a release signature cannot pass until you add your public key (step 4).

The release is `1.0.0` (`v1.0.0`). Until the tag commit (step 1) the version in this repository is the release candidate `1.0.0-rc.1` (the wheel and the sdist write it as `1.0.0rc1`), and `tests/scripts/no-plain-1.0.0.sh` fails
if a plain `1.0.0` appears anywhere before then. Tagging `v1.0.0` today would not be honest: [release.md](release.md) says which rows are yours and still open, and
a write-up must not say anything those rows do not support.

## Owner-only steps, in order

Run the commands from a checkout of `AirplaneMode-Labs/pagetriage` on the commit you intend to release unless a step says otherwise. Replace `<...>` with your own value; none of those values is written in this
repository, and no secret ever goes on a command line or into a file you commit.

### 1. Measure the 8 GB laptop figure

Follow "Owner must", row 2, in [release.md](release.md) on the 8 GB Windows laptop with no GPU, then put the figures in the README Benchmarks table in the "8 GB Windows no-GPU laptop" column and cite where the raw output is kept.

```sh
python -I bench/quality_synth_eval.py --only time
```

Why only you: the machine is yours. Every cell for that laptop reads "not measured on 8 GB" until you fill it, and no figure measured on another machine (not the Mac, not a GitHub runner) may stand in for it.

### 2. Check that the names are free, and reserve them

The names are placeholders until you reserve them: npm scope `@airplanemode` (package `@airplanemode/pagetriage`), PyPI `pagetriage`, crates.io `pagetriage-core` and `pagetriage-cli` (reservation was due on 22 Nov 2026).
Create the npm organisation `airplanemode` on npmjs.com. A PyPI project and a crates.io crate exist only once something is uploaded, so a name is held by the first release itself (a pending publisher on PyPI, step 8, does not hold
it); check that nobody took them first.

```sh
npm view @airplanemode/pagetriage version
pip index versions pagetriage
cargo search pagetriage-core --limit 1
```

If a name is taken, stop and tell the team: a different name is a new decision, not an edit.

Why only you: registry accounts, organisation ownership and any legal or money step are yours; the team has no registry account and creates none.

### 3. Create the real signing key, offline

On the offline key machine, with `cp-sign` from the private `AirplaneMode-Labs/control-plane` repository. The secret never leaves that machine, never goes into any repository, workflow or secret store, and is never used with a test-key flag.

```sh
git clone https://github.com/AirplaneMode-Labs/control-plane && cd control-plane
cargo run -p cp-sign -- keygen --out ./keys
cargo run -p cp-sign -- keyid --pub ./keys/key.pub
```

Record the key id (64 lower-case hex characters) and the public key. `key.pub` is a text file: a comment line, then `ed25519-public <64 hex>`. The `publicKey` that step 4 needs is the canonical padded base64 of those 32 bytes. This command picks the line, refuses (exit 1) unless the hex is exactly 32 bytes, and prints the base64 (`<KEYDIR>` is the directory you gave `--out`):

```sh
node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split(/\r?\n/).find(s=>s.startsWith("ed25519-public "));const b=l&&Buffer.from(l.split(/\s+/)[1],"hex");if(!b||b.length!==32){console.error("not a cp-sign public key file");process.exit(1)}console.log(b.toString("base64"))' <KEYDIR>/key.pub
```

The release key signs only `-release` manifests and is separate from any key that signs models or data (R4, S1-127).

Why only you: no agent handles a real key, and custody (where the secret lives, who can reach it, how you would revoke it) is your decision.

### 4. Commit the public key

Put exactly one key in `docs/release-keys.json` (the file is committed empty today). The format is fixed: the spec string, then the list, each key with `keyId` and `publicKey` (canonical padded base64 of the 32 raw bytes: the output of the step 3 command run on `key.pub`).

```sh
cat > docs/release-keys.json <<'JSON'
{"spec":"airplanemode.release-keys/0.1","keys":[{"keyId":"<64 hex from step 3>","publicKey":"<base64 printed by the step 3 command>"}]}
JSON
```

Do not add the RFC 8032 test key: the verifier refuses it. Commit and push this change on its own. Consider a `CODEOWNERS` entry that makes you the only reviewer of `docs/release-keys.json`, `scripts/release/release-tool.mjs` and `.github/workflows/publish.yml`.

Why only you: which key may sign a release is the one trust decision in this process; the workflow trusts only what is committed here.

### 5. Create the `release` environment

The publish job runs in the `release` environment. You are its required reviewer, deployments are limited to `main`, and administrators cannot bypass it. `prevent_self_review` stays `false` because you are the only reviewer.

```sh
OWNER_ID=$(gh api users/<your-github-login> --jq .id)
gh api -X PUT repos/AirplaneMode-Labs/pagetriage/environments/release --input - <<JSON
{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":$OWNER_ID}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true},"can_admins_bypass":false}
JSON
gh api -X POST repos/AirplaneMode-Labs/pagetriage/environments/release/deployment-branch-policies -f name=main -f type=branch
gh api repos/AirplaneMode-Labs/pagetriage/environments/release --jq '{can_admins_bypass, branch_policy: .deployment_branch_policy, reviewers: [.protection_rules[]? | .reviewers[]? | .reviewer.login]}'
```

Why only you: repository and environment settings belong to the repository owner; the team never changes them.

### 6. Tell the environment which key signs releases

`RELEASE_KEY_ID` is a variable of the `release` environment (not a secret). The publish job compares it with the single key in `docs/release-keys.json` at the commit it publishes and refuses if they differ.

```sh
gh variable set RELEASE_KEY_ID --env release --repo AirplaneMode-Labs/pagetriage --body "<64 hex from step 3>"
```

Why only you: it names your key.

### 7. Make the tag commit (1.0.0-rc.1 becomes 1.0.0), and nothing else in it

This is the first step that may be taken only after step 1: the 8 GB figure is in the README and every other row of [release.md](release.md) that is yours says what it must say. The commit changes the
version and the sentences that were true only before the tag, and nothing else:

1. `Cargo.toml`: `version = "1.0.0-rc.1"` becomes `version = "1.0.0"` under `[workspace.package]`, and in the line `pagetriage-core = { path = "crates/pagetriage-core", version = "1.0.0-rc.1" }`.
2. `Cargo.lock`: run `cargo update --workspace` (it rewrites the four workspace entries `pagetriage-core`, `pagetriage-cli`, `pagetriage-py` and `pagetriage-wasm` and nothing else), then `git diff Cargo.lock` must show those four lines only.
3. `CHANGELOG.md`: the heading `## [1.0.0-rc.1] - 2026-11-20 (untagged)` becomes `## [1.0.0] - YYYY-MM-DD` with the date of the tag.
4. `docs/release.md`: delete the sentence `Tagging v1.0.0 today would not be honest.` (this is what switches `tests/scripts/no-plain-1.0.0.sh` to "skipped: tag commit"), and mark the rows you have closed Done with their evidence.
5. `README.md`: the paragraph that begins `Version 1.0.0-rc.1: a release candidate, untagged` becomes a sentence that says what is true then; in the "Install" section move the "After the owner publishes" commands into the main text only after step 17.
6. `SECURITY.md`: the "Supported versions" table and the sentence under it name `1.0.0-rc.1`; change them to `1.0.0`.

Then run the gate on that commit (`cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --locked`, `scripts/determinism.sh`, `bash tests/scripts/run-all.sh`), push it, and read CI on the pushed commit: every job green on Linux,
macOS and Windows, the three `release-rehearsal` jobs included.

```sh
cargo update --workspace
git diff --stat
git commit -am "release: 1.0.0"
git push origin main
gh run list --repo AirplaneMode-Labs/pagetriage --branch main --limit 3
gh run view <ci-run-id> --repo AirplaneMode-Labs/pagetriage --json jobs --jq '.jobs[] | [.name, .conclusion] | @tsv'
```

Why only you: the version, the date and the claim that the release is honest are yours; the team keeps `1.0.0` out of every file, name and manifest until this commit, so that nothing says "1.0.0" before you do.

### 8. Add the PyPI pending publisher

PyPI publishes through trusted publishing (OpenID Connect), so there is no PyPI token anywhere. On pypi.org, Account settings, Publishing, "Add a new pending publisher", fill in exactly:

- Project name: `pagetriage`
- Owner: `AirplaneMode-Labs`
- Repository name: `pagetriage`
- Workflow name: `publish.yml`
- Environment name: `release`

```sh
gh api repos/AirplaneMode-Labs/pagetriage/environments/release --jq .name
```

Why only you: it is your PyPI account, and the first upload through it creates the project under your name.

### 9. Create the registry tokens as secrets of the environment only

npm and crates.io publish with short-lived tokens that exist only as secrets of the `release` environment (never repository or organisation secrets). Create each token on the registry's own page, with the shortest lifetime that covers the release: 7 days or less
(npm's trusted publishing needs npm 11.5.1 or later, which Node 22 does not bundle, so the first publish uses a token; moving to trusted publishing is decided afterwards, TD-122).

- npm: a granular access token, read and write, limited to the `@airplanemode` scope, expiry 7 days. Tick "bypass two-factor authentication" only if your account requires a second factor for writes, since CI cannot answer a prompt.
- crates.io: an API token with the scopes `publish-new` and `publish-update`, limited to the crate names `pagetriage-core` and `pagetriage-cli`, expiry 7 days.

```sh
gh secret set NPM_TOKEN --env release --repo AirplaneMode-Labs/pagetriage
gh secret set CARGO_REGISTRY_TOKEN --env release --repo AirplaneMode-Labs/pagetriage
```

Each command asks for the value on standard input.

Why only you: only you can create tokens on your registry accounts, and a token is a credential the team must never see.

### 10. Tag the commit

Tag the exact commit of step 7 with a signed annotated tag and push the tag.

```sh
git tag -s v1.0.0 -m "pagetriage 1.0.0"
git push origin v1.0.0
```

Consider a tag ruleset for `v*` that only you can create, update or delete, branch protection on `main`, and secret-scanning push protection.

Why only you: commits, tags and pushes are yours; nobody on the team pushes or tags, and CI is read, not rerun, by them.

### 11. Dispatch the publish workflow (it builds, then waits)

Dispatch from `main`, which must still be the tagged commit. The build jobs run on all three operating systems and upload the candidate files for one day (so do steps 12 to 15 within that day, or dispatch again: a second dispatch builds new files); the publish job then waits for your approval in the `release` environment and runs nothing until you give it. Once you approve, its first step after the checkout refuses unless step 15 has armed the release.

```sh
gh workflow run publish.yml --repo AirplaneMode-Labs/pagetriage --ref main
gh run list --repo AirplaneMode-Labs/pagetriage --workflow publish.yml --limit 1
```

Why only you: the team never runs `publish.yml`, and the workflow itself refuses to start from anywhere but `main` of this repository.

### 12. Check the candidate before you sign it

The candidate files are what you will sign, so check where they came from first. The run must be this dispatch of `publish.yml` on the tagged commit, and the files must be the ones the build jobs printed. Sign the files of the run you will approve: a second dispatch builds new files.

```sh
RUN=<publish run id from step 11>
gh run view $RUN --repo AirplaneMode-Labs/pagetriage --json headSha,headBranch,event,workflowName,status --jq .
test "$(git rev-parse 'v1.0.0^{commit}')" = "<the headSha printed above>" && echo "tag commit equals the run's commit"
mkdir -p candidate cand && gh run download $RUN --repo AirplaneMode-Labs/pagetriage --dir candidate --pattern 'pagetriage-candidate-*'
cp candidate/*/* cand/ && ls cand && shasum -a 256 cand/*
```

`headBranch` must be `main`, `event` must be `workflow_dispatch`, `workflowName` must be `publish`, and `ls cand` must show exactly seven files: `airplanemode-pagetriage-1.0.0.tgz`, `pagetriage-1.0.0.tar.gz`, `pagetriage-core-1.0.0.crate`, `pagetriage-cli-1.0.0.crate`
and one wheel each for manylinux x86_64, macOS arm64 and `win_amd64` (`pagetriage-1.0.0-cp39-abi3-...whl`). Compare each digest with the line of the same name in the build jobs' log step "Print the candidate digests"
(`gh run view $RUN --repo AirplaneMode-Labs/pagetriage --log`). If anything differs, stop: do not sign.

Then compare the candidates with an independent build of the same commit (S1-135). The publish run built these files once, and a compromised build would sign cleanly, so the digests of the npm tarball, the source package and the two `.crate` files must also be the digests of a second build that did not come from the publish run. Use either source.

- **The push CI of the tag commit (preferred; it compares like with like).** The `release-rehearsal` jobs of the CI run on the commit you pushed in step 7 each uploaded `REHEARSAL-test-key-NOT-A-RELEASE-pagetriage-<os>-<commit>` and kept it 3 days (after that, re-run the CI run to get a new one). Every rehearsal artefact lists the sha256 of its files in `dist-release/SHA256SUMS`.

  ```sh
  CI_RUN=<the CI run id of the tag commit from step 7>
  SHA=$(git rev-parse 'v1.0.0^{commit}')
  for os in ubuntu-latest macos-latest windows-latest; do
    gh run download $CI_RUN --repo AirplaneMode-Labs/pagetriage --name "REHEARSAL-test-key-NOT-A-RELEASE-pagetriage-$os-$SHA" --dir "rehearsal/$os"
    while read -r want name; do
      [ -f "cand/$name" ] || continue
      case "$os:$name" in ubuntu-latest:*|*:*.whl) ;; *) continue ;; esac
      have=$(shasum -a 256 "cand/$name" | cut -d' ' -f1)
      [ "$want" = "$have" ] && echo "same ($os): $name" || echo "DIFFERENT ($os): $name"
    done < "rehearsal/$os/dist-release/SHA256SUMS"
  done
  ```

  The Linux artefact is compared for every file; the macOS and Windows artefacts only for their wheel. Each wheel exists for one operating system only, so **a per-OS wheel can be compared only across the two CI builds** (the rehearsal artefact and the publish candidate of that same OS), never with a laptop build of another system.
- **A local build at the tag commit.** `REHEARSE_SDIST=1 bash scripts/release/rehearse.sh all` in a clean checkout of `v1.0.0` builds the tarball, the sdist, the two crates and the wheel of your own system into `dist-release/` (the same script and the same `SOURCE_DATE_EPOCH`, the commit time, as the publish build), then `cmp dist-release/<file> cand/<file>` for each of the four files (not the wheel: see below). The sdist and the crates depend on the sources only. The tarball also depends on the wasm tools: it matches only if your `wasm-bindgen` and `wasm-opt` are the versions pinned in `scripts/install-wasm-tools.sh`, and nobody has yet compared a tarball between two operating systems, so a differing tarball from a laptop is a reason to use the CI source, not yet a finding.

What is known, from the Mac that develops this repository: two builds of the sdist, the wheel, the tarball and the two crates, one after the other from the same tree, were byte-identical. The same sources built in a second directory gave an identical tarball, sdist and crates, and a macOS wheel that differed in 48 of its 3.9 million bytes (the Mach-O UUID and the signature hashes, which follow the build directory; `evidence/sprint-7/D2/green/FR1-build-directory-wheel-1.log`, raw data not kept in this repository: that log was not committed). So a wheel is comparable only between two builds made in the same directory, which two CI builds on one runner image are and a laptop build never is. The sdist and the wheel also change with `SOURCE_DATE_EPOCH`, which is why every release build now defaults it to the commit time. No Linux or Windows runner has produced two builds yet, so the first `same` on those systems is the first evidence. If any line says `DIFFERENT`, stop: do not sign, and find the cause first (a runner image update between the two runs is one possible cause, a compromised build is the other).

Why only you: you are signing these bytes with a key only you hold, so you must be the one who checks they are the right bytes.

### 13. Sign the manifest on the offline key machine

Make the unsigned manifest of exactly those files with the vendored release tool, sign it with `cp-sign` and your real key with no expiry (a release manifest carries no `expiresAt`, TD-121), and check the result with the same tool and the committed key file. Never pass a test-key flag here.

```sh
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct v1.0.0) node scripts/release/release-tool.mjs manifest --dir cand --id pagetriage-release --version 1.0.0 --licence 'MIT OR Apache-2.0' --publisher release
cargo run -p cp-sign -- sign --key ./keys/key.secret --no-expiry cand/release-manifest.json --out release-manifest.json
cp release-manifest.json cand/release-manifest.json
node scripts/release/release-tool.mjs sums --dir cand
node scripts/release/release-tool.mjs verify --dir cand --expect-id pagetriage-release --trust-file docs/release-keys.json
```

The last command must exit 0 and print `"verdict":"ok"` with `"testKey":false`. (Run `cp-sign` from your `control-plane` checkout and give it the absolute paths; the release tool from this checkout.)

Why only you: the real key never leaves the offline machine and no agent handles it.

### 14. Attach the signed manifest to a GitHub release

The publish job downloads `release-manifest.json` from the published GitHub release of tag `v1.0.0`; a draft release is not visible to it. The file must be named exactly `release-manifest.json`.

```sh
gh release create v1.0.0 --repo AirplaneMode-Labs/pagetriage --verify-tag --title "pagetriage 1.0.0" --notes-file release-notes.md release-manifest.json
```

Write `release-notes.md` from [CHANGELOG.md](../CHANGELOG.md) and the README Limitations, and say plainly what the release does not claim (below).

Why only you: creating a GitHub release is publishing; the team creates none.

### 15. Arm, approve, watch

Arm the release only now: after the GitHub release of step 14 exists and just before you approve the waiting job. `RELEASE_PUBLISH_ARMED` is a variable of the `release` environment, so always set it with `--env release` (a repository variable is not what the job reads). The first step of the publish job after the checkout reads it and fails the job unless it is exactly `true`; it is a step and not a job-level `if` because a job-level `if` cannot see a variable of an environment. The job reads it only after you approve, so arming and approving work in either order; never leave it armed (step 16).

Then approve the waiting deployment and watch the publish job. It verifies the manifest against `docs/release-keys.json`, checks the three bindings, attests the exact files, then publishes in this order: the crates, npm (with provenance) and PyPI (with attestations).

```sh
gh variable set RELEASE_PUBLISH_ARMED --env release --repo AirplaneMode-Labs/pagetriage --body true
# Actions > the publish run > "Review deployments" > release > "Approve and deploy"
gh run watch $RUN --repo AirplaneMode-Labs/pagetriage
```

If the job refuses, it says why on its first failing step (the armed variable, a lock, a binding, the verification, the exact file set, the crate digests, the crates.io index). Do not edit the workflow to get past a refusal; fix the cause and dispatch again.

The crates go first, as four steps in a row, because their pre-publish comparison is the check most likely to refuse, so a refusal leaves nothing out on the other two registries: the crates are packaged again at the tagged commit with `cargo package --locked --no-verify` (verification, a build of each crate from its tarball, already ran in the build job and in every `release-rehearsal` job), each digest is compared with the signed manifest, `cargo publish --locked --no-verify` publishes them, and the last step reads each crate's entry back from the crates.io sparse index (retrying for up to 10 minutes) and fails the job loudly if the index `cksum` is not the sha256 you signed.
The crates are in the signed set because two `cargo package --locked` runs of the same tree give byte-identical `.crate` files, and the `--no-verify` run gives the same bytes as the verified one (both logged by every `release-rehearsal` job as `crate reproducibility: identical bytes in two runs` and `the --no-verify bytes equal the verified bytes`). If a rehearsal ever reports different bytes (S1-126), the crates must leave the signed set:
they are then published from source at the tagged commit (`pagetriage-core`, then `pagetriage-cli`) and this page and [release.md](release.md) must say so before you release.

A published crate, npm package or PyPI file cannot be deleted or replaced, and the job refuses a version that a registry already holds. If a step fails after the crates are out, do not dispatch again to get past it: stop, say what happened, and decide the next patch version with the team.

Why only you: the approval is the lock that makes you the only person who can publish, and the variable is the second.

### 16. Disarm, delete the secrets, revoke the tokens

As soon as the publish job ends, whether it succeeded or not:

```sh
gh variable delete RELEASE_PUBLISH_ARMED --env release --repo AirplaneMode-Labs/pagetriage
gh secret delete NPM_TOKEN --env release --repo AirplaneMode-Labs/pagetriage
gh secret delete CARGO_REGISTRY_TOKEN --env release --repo AirplaneMode-Labs/pagetriage
```

Then revoke both tokens on npmjs.com and crates.io (a 7-day token is a limit, not a reason to leave it alive), and check the registries list the new version.

Why only you: they are your credentials on your accounts.

### 17. Install from a clean machine, update the README, write it up

On a machine that has never seen this repository, with Wi-Fi on, run the registry commands and record the output. Then move the README Install section's "After the owner publishes" commands into the main text, mark the rows of [release.md](release.md)
that are now Done with the recorded output, finish the write-up from [writeup-1.0-draft.md](writeup-1.0-draft.md) (it waits for step 1's figure) and publish it.

```sh
python3 -m venv v && v/bin/pip install pagetriage==1.0.0 && v/bin/python -I -c "import pagetriage_py; print(len(pagetriage_py.schema_json()))"
mkdir t && cd t && npm init -y && npm i @airplanemode/pagetriage@1.0.0 && node -e 'console.log(require("@airplanemode/pagetriage").version())'
cargo install pagetriage-cli --locked && pagetriage --version
```

Why only you: it needs a registry that is not empty, a clean machine you control, and your name on the write-up; posting or announcing anything is yours.

### If a publish step fails

The publish job publishes in this order: the crates, then npm, then PyPI. A failure part-way leaves some registries holding the version and others not. A registry never lets you publish a version twice, so recovery is to undo what you can, close the door, and move to a new version.

1. Disarm, so nothing can start again: `gh variable set RELEASE_PUBLISH_ARMED --env release --body false --repo AirplaneMode-Labs/pagetriage`. Why only you: the variable lives in an environment you configured and the team has no write access to repository settings.
2. Record the run id of the failed run (`gh run list --workflow publish.yml --repo AirplaneMode-Labs/pagetriage`) and which registries now hold the version (the three lookups of step 17, without installing). Write both in the release notes or an issue. Why only you: the record is yours to keep and the team cannot read your registry accounts.
3. Crates already published: `cargo yank --version <v> pagetriage-core` and `cargo yank --version <v> pagetriage-cli`, where `<v>` is the version just published. A yank stops new resolution; it does not delete. Why only you: it needs your crates.io login or token.
4. An npm version already published: `npm deprecate "@airplanemode/pagetriage@<v>" "do not use: failed release, see the next version"`. `npm unpublish "@airplanemode/pagetriage@<v>"` is allowed only within 72 hours of publishing and only if nothing depends on it; after that, deprecate is the only option. Why only you: it needs your npm login and two-factor code.
5. A PyPI version already published: yank the release on the project page (PyPI has no delete-and-reuse). Why only you: it needs your PyPI account.
6. Revoke both tokens now, on npmjs.com and crates.io, and delete the environment secrets: `gh secret delete NPM_TOKEN --env release --repo AirplaneMode-Labs/pagetriage` and `gh secret delete CARGO_REGISTRY_TOKEN --env release --repo AirplaneMode-Labs/pagetriage`. Why only you: they are your credentials on your accounts.
7. Do not re-tag, and never re-publish the same version: bump the version (`1.0.1`, or the next release candidate), make a new tag commit as in step 7, and start again from step 9 with fresh tokens. Why only you: the tag, the version choice and the push are yours.

## Settings worth turning on

These are repository settings, so they are yours too; none blocks a release: a tag ruleset for `v*`, branch protection on `main`, secret-scanning push protection, private vulnerability reporting (the SECURITY.md contact is an email address until you turn it on),
and a `CODEOWNERS` file for `docs/release-keys.json`, `scripts/release/release-tool.mjs` and `.github/workflows/publish.yml`.

## What a release does not claim

pagetriage 1.0.0 was checked on synthetic pages only: no real deed has been looked at, and no confidence is calibrated ([detectors/fusion.md](detectors/fusion.md)). Nothing was measured on an 8 GB Windows no-GPU laptop (not measured on 8 GB)
until step 1, and nothing is signed until step 13. A release note should say so in the same words, and the README Limitations section is the list.

## The older release scripts

The unsigned-manifest script `scripts/release-manifest.mjs` (path-confined to `dist/`, tested by `tests/scripts/release-manifest.sh`) and `scripts/prove-install.sh` (a wheel and a tarball into `python3 -m venv`, `uv venv` and a fresh npm directory, offline) are still here and still tested. The release tool
(`scripts/release/release-tool.mjs`, runtime's, vendored byte for byte) writes the same manifest for the same files (`tests/scripts/release-tool-vendored.sh` compares the bytes), and it is what steps 13 and the publish job use.

## When real labelled pages exist

1. Put the pages and a `labels.json` (format in the header of `bench/eval_real.py`) outside the repository or under `bench/data/`, which is git-ignored. They contain personal data: never commit them.
2. `python -I bench/eval_real.py PAGES_DIR --calibration-csv labelled.csv` prints precision and recall per kind and the page-type accuracy, and writes every finding with its raw confidence and whether it matched.
3. `python -I bench/fit_calibration.py labelled.csv > calibration_override.toml` fits the maps; check them on pages not used for the fit, then copy the maps into `params/calibration.toml`.
4. Replace the "synthetic only" lines in the detector docs with the measured numbers.
