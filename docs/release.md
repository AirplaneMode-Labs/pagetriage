# Release checklist

One row per item of the definition of done that every Airplane Mode Labs release must meet. A row is
Done only when the Evidence column names a file or command that proves it today; anything else is
Open. Nothing may be tagged while a Blocker-for-tag row is Open. The first release will be 1.0.0; the
workspace version stays 0.1.0 until the tag commit (step 1 below), and the notes for it live under
`## [Unreleased]` in [CHANGELOG.md](../CHANGELOG.md).

Status as of 2026-11-14 (Sprint 4), after the move to `AirplaneMode-Labs/pagetriage`. Evidence paths
under `evidence/sprint-3/D2/` and `evidence/sprint-4/D2/` are the copies the architect makes at wrap-up.
Sprint 4 closed no further row: every Open row needs the owner (8 GB laptop, real key, registry names,
tag, write-up). What Sprint 4 did change is evidence inside row 6 (notices, below) and the
History note.

| # | Definition-of-done item | Status | Evidence | Owner | Blocker-for-tag |
|---|---|---|---|---|---|
| 1 | Tests written before the implementation; CI green on Linux, macOS and Windows | Tests-first evidence Done (red/green logs); local macOS green; CI on three OSes configured, pending the owner's push | Tests first: every detector has a golden input and expected report under `tests/golden/`; the Sprint 3 script (`scripts/release-manifest.mjs`) has `red-D2-02.log` before `green-D2-02.log` in `evidence/sprint-3/D2/`. Local macOS: `cargo fmt`, `clippy -D warnings`, `cargo test`, `scripts/determinism.sh` and `tests/scripts/run-all.sh` pass (`evidence/sprint-3/D2/gates-s3.log`; Sprint 4 re-run: `evidence/sprint-4/D2/gates-s4.log`). The three-OS matrix is configured in `.github/workflows/ci.yml`. Its last run, on the commit pushed on 9 Nov 2026, was green on `ubuntu-latest`, `macos-latest` and `windows-latest` ([run](https://github.com/AirplaneMode-Labs/pagetriage/actions/runs/42634433346)); the Sprint 3 changes have not been pushed, so no CI run covers them. Not marked Done until the owner pushes and reads CI | D2, then owner (push, read CI) | no |
| 2 | Benchmark on an 8 GB laptop recorded in the README | Open | README [Benchmarks](../README.md#benchmarks) carries one Apple-silicon speed figure (quality pass on one synthetic A4 page at 150 dpi, `evidence/sprint-3/D2/bench-quality-time.log`) labelled as a placeholder; the 8 GB Windows no-GPU column reads "not measured" on every row. Full-page analysis time and thread-pool throughput are not measured by a repo script yet (bench scripts cut to Sprint 6). No figure for that machine exists, and none was invented. The procedure is below | owner | yes |
| 3 | README limitations section | Done | README [Limitations](../README.md#limitations): synthetic-only checks, nothing published or tagged, Linux and Windows wheels not built, nothing signed, target hardware unmeasured; detector limits follow | D2 | no |
| 4 | Signed artifacts and manifest | Open | Tooling exists, signing does not. `scripts/release-manifest.mjs` writes an unsigned `airplanemode.manifest/0.1` (tests: `tests/scripts/release-manifest.sh`, `evidence/sprint-3/D2/red-D2-02.log` then `green-D2-02.log`). A dry run with the public RFC 8032 test key through `cp-sign` verified with `--allow-test-key` and was refused without it (`evidence/sprint-3/D2/dry-run-sign.log`). That signature proves the tooling only: it is not a release signature, and no signed manifest or key is in this repository. A real key does not exist yet | owner, D6 (tooling) | yes |
| 5 | CHANGELOG and semver tag | Open | [CHANGELOG.md](../CHANGELOG.md) `[Unreleased]` is complete through Sprint 3 and holds the 1.0.0 notes. The tag does not exist (`git tag` prints nothing) and must not be created until every row above and below is Done. The version is still 0.1.0 | owner | yes |
| 6 | Package installable from a clean machine | Open | Installed offline from locally built artifacts on macOS arm64, each followed by a real analysis of a synthetic golden page that is byte-equal to its golden report: wheel `pagetriage-0.1.0-cp39-abi3-macosx_11_0_arm64.whl` into a `python3 -m venv` (`pip install --no-index --no-deps`) and into a `uv venv` (`uv pip install --offline --no-index --no-deps`) (`evidence/sprint-3/D2/install-all-r2.log`); `pagetriage-0.1.0.tgz` from `npm pack` into a fresh empty directory with an empty cache (`npm i <tgz> --ignore-scripts --offline`; `npm ls` shows one package) (`evidence/sprint-3/D2/install-all-r2.log`, same run). Both artifacts carry `LICENSE-MIT`, `LICENSE-APACHE`, no test data, no lifecycle script, nothing over 5 MB, and the "Not published yet" sentence in their README. `cargo package -p pagetriage-core --no-verify --list --allow-dirty` lists 134 files and `-p pagetriage-cli` lists 9 (`cargo-package-list-r2.log` and `cargo-package-list-cli-r2.log`, regenerated after the licence copies), and both crates carry `LICENSE-MIT` and `LICENSE-APACHE` in those lists; the wheel and tarball contain no builder path (`scripts/check-no-builder-paths.sh`, `evidence/sprint-3/D2/builder-paths-r2.log`). The wheel and tarball were rebuilt after the last README edit, so their packaged README equals the repo README; their SHA-256 values are in `FINAL-ARTIFACTS.txt` and `release-manifest-r2.json`. Sprint 4 (S1-082): the wheel now lists `NOTICE` under `dist-info/licenses/` (`evidence/sprint-4/D2/wheel-listing.log`, wheel SHA-256 in `evidence/sprint-4/D2/FINAL-ARTIFACTS.txt`, no builder path), and the demo NOTICE carries a full block for each of the 8 MIT-only crates compiled into the WASM build, and the root NOTICE, so the rebuilt wheel (SHA-256 in `evidence/sprint-4/D2/FINAL-ARTIFACTS.txt`, `evidence/sprint-4/D2/green-fix1-D2-notice.log`), carries the same 8 blocks for the `pagetriage-py` tree (TD-28) (`evidence/sprint-4/D2/green-D2-01.log`, mutation check in `mutation-D2-01.log`); the alloc-stdlib attribution is checked against upstream (`evidence/sprint-4/D2/upstream-licence.log`). Not closed: nothing is published, the names are not reserved, only the macOS arm64 wheel exists (Linux and Windows wheels and an sdist are cut to Sprint 6), and no clean machine has installed from a registry | owner | yes |
| 7 | Short write-up | Open | [writeup-1.0-draft.md](writeup-1.0-draft.md) is a draft, not published, built from existing evidence only, with every figure citing a path and the 8 GB figures reading "not measured". It cannot be finished before row 2 closes | owner | yes |

Blocker-for-tag rows Open today: 2, 4, 5, 6, 7. Tagging v1.0.0 today would not be honest.

## History

The AI-attribution trailer lines in 25 commits pushed between 2026-10-25 and 2026-10-27 are left as they are: rewriting pushed history needs a force push, which the team does not do (team decision under owner delegation, 14 Nov 2026). The count and range come from a case-insensitive `git log --grep` for the two trailer tokens (`evidence/sprint-4/D2/trailers.log`); all 25 are ancestors of `origin/main`. The trailers are attribution metadata, not secrets or employer data. The owner may reverse this decision.

## Known gaps in the version-pinned installs

Every `cargo` and `maturin` invocation in CI and in `scripts/` uses `--locked` with `Cargo.lock` committed (S1-093).
Two installs are pinned by version only, not by hash. Each runs in a job or script that publishes nothing and uses no
secrets (`contents: read`), and the wheel it builds is never shipped from CI:

- `scripts/determinism.sh` installs `maturin==1.16.0` into a test-only venv;
- `scripts/package-python.sh` installs `maturin==1.16.0` into a local venv to build the wheel the owner inspects. Before a
  wheel is built in CI for release, this becomes `pip install --require-hashes -r <hashed requirements>`, as in glyphsift's
  `tools/ci/requirements.txt`.

The pip that `actions/setup-python` ships is not pinned either, and the digest-pinned `wasm-bindgen`, `wasm-opt` and
`cargo-deny` release binaries are pinned by SHA-256, not by a lockfile.

Known gap: MIT-only crates linked only into `pagetriage-cli` (fax 0.2.7, strsim 0.11.1, tiff 0.11.3) are not yet in NOTICE. No CLI binary is distributed in Sprint 4. `gen-site-notice.mjs` and `build-site-notices.sh` must cover the `pagetriage-cli` tree before any CLI binary or CLI-bearing artefact ships (Sprint 6, with the Linux and Windows wheels). The list comes from `cargo tree --locked -p pagetriage-cli -e normal` plus `cargo metadata --locked` (BUG-T3-S4-19).

## Owner must

Summary of what only the owner can do (the team does not do any of it): the 8 GB bench; the real key and
signing; reserve the names and publish; the tag; the write-up. Cut to Sprint 6 and so not available to
close any row before then: Linux and Windows wheels and an sdist, and the full-page and large-document
bench scripts.

Each Open row, with the commands. Run them from a checkout of `AirplaneMode-Labs/pagetriage`.

**Row 2, benchmark on the 8 GB Windows no-GPU laptop.**

Owner must:

Use the target machine itself (8 GB RAM, no discrete GPU, a current Windows 10 or 11, Chrome). Invent
nothing: write down what the commands print.

1. Record the machine: Windows version (`winver`), CPU model, RAM, whether a GPU is present
   (`Get-CimInstance Win32_VideoController`), Chrome version, and that Wi-Fi is off for the browser run.
2. Install Python 3.12, Rust (`rustup` reads `rust-toolchain.toml`) and Node 22, then:

   ```powershell
   python -m venv .venv; .\.venv\Scripts\Activate.ps1
   pip install maturin -r bench/requirements.txt
   maturin develop --locked --release -m crates/pagetriage-py/Cargo.toml
   python -I bench/quality_synth_eval.py --only time
   ```

   `quality_synth_eval.py --only time` measures one thing: the quality pass on one synthetic A4 page at
   150 dpi, wall time of the Python call with the JSON, median, min and max over repeated runs. It is the
   same quantity as the README Benchmarks speed row, so its median goes in the "8 GB Windows no-GPU laptop"
   column of that row. It does not measure full-page `analyse_page`, rendering or throughput: no repo
   script does yet (cut to Sprint 6), so leave those "not measured". Do not time `pagetriage.exe` on
   `tests\golden\inputs\blank_speckle.pgm`: that is a process start on a tiny image, not an A4 page.
3. Peak memory: no memory tool exists in this repository. Open Task Manager, Details tab, add the
   "Peak working set (memory)" column, and read it for `python.exe` during the `quality_synth_eval.py`
   run and for the Chrome tab process during the browser run. Write the figure and where it came from.
4. Browser (WebAssembly): `scripts/install-wasm-tools.sh`, then `PAGETRIAGE_WASM_FEATURES=pdf scripts/build-wasm.sh`
   and `scripts/build-site.sh` (Git Bash), serve `site/` locally, turn Wi-Fi off, open it in Chrome and
   analyse the eight sample pages. Time them with DevTools, Performance, and record the numbers.
5. Put the results in the README Benchmarks table (the "8 GB Windows no-GPU laptop" column of the speed row and
   the in-browser row), cite where the raw output is kept (for example `evidence/` in the repository), and change the
   Status line of row 2 to Done in this file.

**Row 4, signed artifacts and manifest.**

Owner must: on the offline key machine (not this Mac, not CI):

```sh
git clone https://github.com/AirplaneMode-Labs/control-plane && cd control-plane   # private repo
cargo run -p cp-sign -- keygen --out ./keys            # key.secret stays on this machine, mode 0600
cargo run -p cp-sign -- keyid --pub ./keys/key.pub     # record the keyId in the repository's release notes
```

Then, after the artifacts exist (rows 5 and 6 steps), in the pagetriage checkout:

```sh
node scripts/release-manifest.mjs --out dist/release-manifest.json dist/npm/pagetriage-X.Y.Z.tgz dist/wheels/*.whl
cargo run -p cp-sign -- sign --key ./keys/key.secret dist/release-manifest.json --out dist/release-manifest.signed.json
cargo run -p cp-sign -- verify --pub ./keys/key.pub dist/release-manifest.signed.json
```

Publish `release-manifest.signed.json` and `key.pub` next to the artifacts ([RELEASING.md](RELEASING.md),
"Signing the manifest"; tag procedure step 7 below). Never use `--allow-test-key` for a release.

**Row 5, CHANGELOG and semver tag.**

Owner must: after rows 2, 4, 6 and 7 are Done and CI is green on the tag commit:
follow the tag procedure below from step 1. `git tag v1.0.0` is run by the owner only.

**Row 6, installable from a clean machine.**

Owner must:

1. Reserve the names (due 22 Nov 2026): npm `pagetriage` (or `@airplanemode/pagetriage` after the scope
   exists), PyPI `pagetriage`, crates.io `pagetriage-core` and `pagetriage-cli`.
2. Publish per tag-procedure steps 4 to 6 below (crates.io, PyPI with wheels for Linux, macOS and Windows,
   npm).
3. On a machine that has never seen this repository, with Wi-Fi on, run the commands in the block headed
   "After the owner publishes" below, and record the output.
4. Change the README Install section so the "After the owner publishes" commands move into the main text,
   and mark row 6 Done with the recorded output as evidence.

**After the owner publishes** (step 3; these registry commands do not work today):

```sh
python3 -m venv v && v/bin/pip install pagetriage==X.Y.Z && v/bin/python -I -c "import pagetriage_py; print(len(pagetriage_py.schema_json()))"
mkdir t && cd t && npm init -y && npm i pagetriage@X.Y.Z && node -e 'console.log(require("pagetriage").version())'
cargo install pagetriage-cli && pagetriage --version
```

**Row 7, short write-up.**

Owner must: when row 2 has numbers, finish [writeup-1.0-draft.md](writeup-1.0-draft.md):
replace each "not measured" with the measured figure and its evidence path, remove the "Draft, not
published" heading, publish it (the demo page is its natural home), and mark row 7 Done.

**Row 1, after the push.**

Owner must: `git push`, then read the CI run for the pushed commit on
`ubuntu-latest`, `macos-latest` and `windows-latest` (`gh run list --repo AirplaneMode-Labs/pagetriage`),
and change row 1's status to Done only when all three are green.

## Tag procedure (owner only, in this order)

Taken from [RELEASING.md](RELEASING.md); do not start it while any Blocker-for-tag row is Open.

1. **Bump the version.** Set `version = "1.0.0"` under `[workspace.package]` in `Cargo.toml` and let
   `cargo build` update `Cargo.lock`; the wheel and the npm package take the version from there.
   Move the `[Unreleased]` notes in `CHANGELOG.md` under `## [1.0.0] - YYYY-MM-DD`. This is the tag
   commit; nothing else goes in it.
2. **Run the gate** on that commit: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets
   -- -D warnings`, `cargo test`, `scripts/determinism.sh`, and the three packaging dry runs. CI must be
   green on Linux, macOS and Windows for the commit.
3. **Tag** `v1.0.0` on that commit and push the tag.
4. **crates.io.** `cargo publish -p pagetriage-core`, then `cargo publish -p pagetriage-cli`.
5. **PyPI.** Build manylinux, macOS and Windows wheels (`maturin-action` in CI or a manylinux
   container), then `maturin upload` or `twine upload dist/wheels/*`.
6. **npm.** `npm publish dist/npm/pagetriage-1.0.0.tgz` (`--access public` for a scoped name).
7. **Sign.** Write the manifest listing the artefacts with their SHA-256 (`node scripts/release-manifest.mjs
   --out dist/release-manifest.json <artefacts>`), sign it with `cp-sign` and the real key on the offline
   key machine (see "Owner must", row 4), and publish the signed manifest with the release.
8. **Site and write-up.** The `pages` workflow deploys `site/` on the push; publish the write-up.

Do not tag until every Blocker-for-tag row is Done.
