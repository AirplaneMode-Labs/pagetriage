# Release checklist

One row per item of the definition of done that every Airplane Mode Labs release must meet. A row is
Done only when the Evidence column names a file or command that proves it today; anything else is
Open. Nothing may be tagged while a Blocker-for-tag row is Open. The first release will be 1.0.0; the
workspace version is the release candidate 1.0.0-rc.1 (the wheel and the sdist write it as 1.0.0rc1) until the owner's tag commit
([RELEASING.md](RELEASING.md), step 7), which is the only change to 1.0.0, and the notes for it live under
`## [1.0.0-rc.1]` in [CHANGELOG.md](../CHANGELOG.md).

Status as of 2026-11-20 (Sprint 7). Evidence paths under `evidence/sprint-N/D2/` are the copies the architect makes at wrap-up.
Sprint 7 closed every row the team could close: what is left is owner-only, and each open row says why. The owner's steps, in order, with the
commands and the reason the team cannot take each one, are in [RELEASING.md](RELEASING.md); the team's side (the artefacts, the
`release-rehearsal` CI job, `publish.yml` and its checks) is listed there too.

| # | Definition-of-done item | Status | Evidence | Owner | Blocker-for-tag |
|---|---|---|---|---|---|
| 1 | Tests written before the implementation; CI green on Linux, macOS and Windows | Done for the Sprint 6 head; the Sprint 7 commits wait for the push | Tests first: every detector has a golden input and expected report under `tests/golden/`; every Sprint 7 task has a red log older than its green log (`evidence/sprint-7/D2/red/`, `green/`). CI at the Sprint 6 head 1a6a244 (the main session's push of 19 Nov 2026): all 13 jobs of [run 44584709767](https://github.com/AirplaneMode-Labs/pagetriage/actions/runs/44584709767) succeeded on `ubuntu-latest`, `macos-latest` and `windows-latest` (`evidence/sprint-7/D2/partA-ci.log`). The Sprint 7 commits are read by the main session after its push (the jobs are listed in "Sprint 7: what only CI can prove" below); local macOS: `cargo fmt`, `clippy -D warnings`, `cargo test --locked`, `scripts/determinism.sh` and `tests/scripts/run-all.sh` pass (`evidence/sprint-7/D2/green/`) | main session (push, read CI), then owner | no |
| 2 | Benchmark on an 8 GB laptop recorded in the README | Open | README [Benchmarks](../README.md#benchmarks) carries one Apple-silicon speed figure (quality pass on one synthetic A4 page at 150 dpi, `docs/benchmarks/eval-quality-time.json`) labelled as a placeholder; the 8 GB Windows no-GPU column reads "not measured on 8 GB" on every row. Full-page analysis time and the large-document figures have bench scripts and CSV files since Sprint 6 (`docs/benchmarks/speed.csv`, `large-doc.csv`, Apple M5 Pro 48 GB only); thread-pool throughput is not measured. No figure for that machine exists, and none was invented. Every figure the README, `docs/` and the demo quote has its raw file under `docs/benchmarks/` (owner decision, 20 Nov 2026; [docs/benchmarks/README.md](benchmarks/README.md) is the index, `tests/scripts/benchmarks.sh` fails for a quoted figure with no matching row). The procedure is below | owner | yes |
| 3 | README limitations section | Done | README [Limitations](../README.md#limitations): synthetic-only checks, nothing published or tagged, Linux and Windows runs not yet seen, nothing signed with a real key, target hardware unmeasured; detector limits follow | D2 | no |
| 4 | Signed artifacts and manifest | Open: the real key is the owner's | The team's side is done. `scripts/release/release-tool.mjs` (runtime's release tool, vendored byte for byte, `scripts/release/VENDORED.json`) writes the manifest and `SHA256SUMS`; the CI job `release-rehearsal (<os>)` signs a `pagetriage-rehearsal` manifest with the published RFC 8032 test key, verifies it with `--allow-test-key`, and proves by exact exit code and first stderr line that the same files are refused without the flag (`refused: test_key_refused`), that the empty production key file `docs/release-keys.json` gives `no_trusted_key`, that a missing `--expect-id` is a usage error, that a test key never signs a `-release` id, and that a tampered file and a CRLF `SHA256SUMS` are refused (local macOS run: `evidence/sprint-7/D2/green/D2-02-rehearse-all-nosiblings-1.log`). `publish.yml` verifies the owner's signed manifest against `docs/release-keys.json` before it publishes anything; the release is armed by the `release` environment variable `RELEASE_PUBLISH_ARMED`, which the first step after the checkout reads (a job-level `if` cannot read an environment variable, TD-125), and the crates are re-packaged with `cargo package --locked --no-verify`, compared with the signed digests, published, and read back from the crates.io sparse index in four steps in a row before the PyPI step (S1-131). That signature proves the tooling only: it is not a release signature, no signed manifest or real key is in this repository, and `docs/release-keys.json` holds no key until the owner adds one | owner (real key and custody) | yes |
| 5 | CHANGELOG and semver tag | Open: the tag is the owner's | [CHANGELOG.md](../CHANGELOG.md) has `## [1.0.0-rc.1] - 2026-11-20 (untagged)` with the notes for the release. The tag does not exist (`git tag` prints nothing) and must not be created until every row above and below is Done. The version is the release candidate 1.0.0-rc.1: nothing in the repository, no artefact name, no manifest and no demo label reads a plain 1.0.0 (`tests/scripts/no-plain-1.0.0.sh`), and the owner's tag commit is the only change to 1.0.0 ([RELEASING.md](RELEASING.md), step 7) | owner | yes |
| 6 | Package installable from a clean machine | Open: names, publish and a registry install are the owner's | Installed offline from locally built artifacts on macOS arm64, each followed by a real call on a synthetic golden page (byte-equal to its golden report): Sprint 3, version 0.1.0 (`evidence/sprint-3/D2/install-all-r2.log`), and Sprint 7, version 1.0.0-rc.1, by `scripts/release/rehearse.sh` in a copy of the repository with no sibling repository and GITHUB_SHA and GITHUB_REF cleared: the npm tarball `airplanemode-pagetriage-1.0.0-rc.1.tgz` into an empty project (offline, a fresh cache, `--ignore-scripts`, resolved under that project's `node_modules`), the wheel `pagetriage-1.0.0rc1-cp39-abi3-macosx_11_0_arm64.whl` into a fresh `.venv` (`pip --no-index --no-deps`), and the command-line tool built from the two packaged `.crate` files with every other crate from a `cargo vendor --locked` directory and `cargo install --offline --locked`, run by absolute path outside the checkout (`evidence/sprint-7/D2/green/D2-02-rehearse-all-nosiblings-1.log`). The `release-rehearsal (<os>)` CI job does the same on Linux, macOS and Windows, with an sdist and a wheel built from it on Linux; it has not run on Linux or Windows. The archives hold the licence files and no test data, source maps, lifecycle scripts or files over 5 MB, and no builder path (`scripts/check-no-builder-paths.sh`). Not closed: nothing is published, the names are not reserved, and no clean machine has installed from a registry | owner | yes |
| 7 | Short write-up | Draft exists; finishing it waits on the 8 GB figure (owner) | [writeup-1.0-draft.md](writeup-1.0-draft.md) is a draft, not published, built from existing evidence only, with every figure citing a path and the 8 GB figures reading "not measured on 8 GB". It cannot be finished before row 2 closes | owner | yes |

Blocker-for-tag rows Open today: 2, 4, 5, 6, 7, and every one of them is the owner's (the 8 GB figure, the real key, the tag, reserved names and a registry install, finishing the write-up). Tagging v1.0.0 today would not be honest.

## History

The AI-attribution trailer lines in 25 commits pushed between 2026-10-25 and 2026-10-27 are left as they are: rewriting pushed history needs a force push, which the team does not do (team decision under owner delegation, 14 Nov 2026). The count and range come from a case-insensitive `git log --grep` for the two trailer tokens (`evidence/sprint-4/D2/trailers.log`); all 25 are ancestors of `origin/main`. The trailers are attribution metadata, not secrets or employer data. The owner may reverse this decision.

## Known gaps in the version-pinned installs

Every `cargo` and `maturin` invocation in CI and in `scripts/` uses `--locked` with `Cargo.lock` committed (S1-093).
Two installs are pinned by version only, not by hash. Each runs in a job or script that publishes nothing and uses no
secrets (`contents: read`), and the wheel it builds is never shipped from CI:

- `scripts/determinism.sh` installs `maturin==1.16.0` into a test-only venv;
- `scripts/package-python.sh` installs `maturin==1.16.0` into a local venv to build the wheel the owner inspects; the README's "Try it in two minutes" setup block calls it. In CI the quick start runs from the artefacts that `release-rehearsal` built with the hashed tools, and skips that block (`QUICKSTART_REUSE=1`).

Since Sprint 6 the artefact-building CI job does not use either: the `release-rehearsal` job (which absorbed the `wheels` job in Sprint 7) and the `publish.yml` build job install uv, maturin and ziglang from the hashed
`tools/ci/requirements.txt` (`pip install --require-hashes --no-deps --only-binary=:all:`, on an exact Python), and the determinism
job installs numpy and Pillow from `tools/ci/requirements-determinism.txt` the same way (S1-117, S1-079). `tests/scripts/ci-policy.sh`
keeps those rules, the action pins and the permissions of `release-rehearsal` and `publish.yml` from drifting (`tests/scripts/ci-policy-mutations.sh` breaks one rule at a time and shows the policy go red).

The exact Python is one CPython 3.12 patch release per OS, set in the `matrix.include` of the `determinism` and `release-rehearsal` jobs (and `publish.yml`'s build job): 3.12.10 on
`macos-latest` and `windows-latest`, 3.12.16 on `ubuntu-latest`. No single patch release exists on all three images in
`actions/python-versions` (`versions-manifest.json`, read 19 Nov 2026): 3.12.10 is the last 3.12 with a macOS or Windows build, and the
ubuntu-26.04 image behind `ubuntu-latest` has only 3.12.13 and newer. The hashed files are for the cp312 wheels, which the patch release
does not change. When `ubuntu-latest` moves to a newer image, `setup-python` fails with "was not found for Ubuntu"; read the manifest,
choose an exact release for the new image (or the next Python, with newly compiled hashes) and change both jobs together.

The pip that `actions/setup-python` ships is not pinned either, and the digest-pinned `wasm-bindgen`, `wasm-opt` and
`cargo-deny` release binaries are pinned by SHA-256, not by a lockfile.

MIT-only crates linked only into `pagetriage-cli` (fax 0.2.7, strsim 0.11.1, tiff 0.11.3, and crunchy 0.2.4, which is in the tree only for non-macOS targets) are in `crates/pagetriage-cli/NOTICE` since Sprint 6 (BUG-T3-S4-19, BUG-T3-S4-21). `scripts/notice-cli.mjs` writes it from `cargo tree --locked -p pagetriage-cli --target all -e normal` plus `cargo metadata --locked` (the tree for all targets, so a build on Linux or Windows is covered as well as one on macOS), and `tests/scripts/notice-cli.sh` checks the committed file against cargo and against the generator, with a mutation step that must fail when a block is removed. No CLI binary is distributed.

`pagetriage-core` is a published and signed crate too, and its packaged `.crate` shipped without a NOTICE until Sprint 7 (BUG-T3-S7-04). `crates/pagetriage-core/NOTICE` is now the project notice plus a block for each MIT-only crate of `cargo tree --locked -p pagetriage-core --features pdf --target all -e normal` (libm, lopdf, nom, schemars, schemars_derive, simd-adler32, winnow, zmij), written by the same generator (`node scripts/notice-cli.mjs --package pagetriage-core crates/pagetriage-core/NOTICE`; licence unchanged, MIT OR Apache-2.0) and checked by `tests/scripts/notice-core.sh`. The release rehearsal's gate (`scripts/release/rehearse.sh gate`, through `scripts/release/check-crate.py`) now requires `LICENSE-APACHE`, `LICENSE-MIT` and a non-empty `NOTICE` inside every `.crate` in `dist-release/`, and `tests/scripts/rehearse.sh` shows it refusing a crate that lacks any one of them.

## Output confinement of `release-manifest.mjs` (Sprint 5, Part A)

`node scripts/release-manifest.mjs --out <file> <artifact>...` writes only to a regular file inside this
repository's `dist/`. The check and the write live in `scripts/lib/confine.mjs`, which takes `{pathMod, fs,
platform}` so that every rule below is unit-tested on any OS (`tests/scripts/confine.test.mjs`, with
`path.win32` and an in-memory volume) and again against real files and real links (`tests/scripts/release-manifest.sh`).
Any refusal exits 2 and writes nothing.

Rules, in the order they are applied:

1. `--out` is not empty and has no NUL; no component is `..` (backslash counts as a separator for this test on
   every OS).
2. On Windows only, on the text as typed: no `\\?\` or `\\.\` prefix; no UNC path (`\\server\share`, also
   `//server/share` and the admin share of the local drive); no drive-relative path (`C:name`, `C:dir\name`,
   `C:`), whose meaning depends on a per-drive working directory; no `:` after the drive (an alternate data
   stream, `name:stream`); no reserved device name (`CON PRN AUX NUL COM1-9 LPT1-9 CONIN$ CONOUT$`, any case, with or
   without an extension); no component ending in `.` or a space (Windows strips them, so the name on disk
   would not be the name that was checked); no character Windows forbids in a file name (`< > " | ? *` and
   control characters).
3. `dist/` and the deepest existing ancestor of `--out` are resolved with `fs.realpathSync.native`. On Windows
   that expands 8.3 short names (`RUNNER~1`), gives each name its on-disk case, uppercases the drive letter and
   follows every symlink and junction, including a reparse point that `lstat` does not report as a link. A
   dangling link on the way is refused.
4. If `--out` itself exists it must be a regular file. A symbolic link or junction is refused whatever it
   points at (even a file inside `dist/`), and so is a directory, a FIFO, a socket or a device. A regular file or
   a dangling link at `dist/` itself is a one-line refusal (exit 2), not a stack trace.
5. Containment: `rel = relative(distReal, final)` must be non-empty, not absolute (another drive), and not `..`
   or start with `..` plus a separator (a file called `..foo` is fine). The comparison is case-insensitive on
   Windows only because `path.win32.relative` is, and only after step 3 made both sides canonical; elsewhere it
   is exact, so a difference in spelling can refuse a path but never accept one.
6. The bytes go to a temporary name (`.release-manifest-<random>.tmp`) opened with the `wx` flag inside the
   realpath'd parent, are flushed, and are renamed over the target. The parent is resolved and checked a
   second time just before the temporary file is created. `rename` replaces a link at the target instead of
   following it.

What is not closed: between the second check and the `rename` another process that can already write inside
`dist/` could replace a directory by a link. This is a local tool run by the owner on their own checkout, so
that process would have to be the owner's own account; the window is narrowed, not removed, and nothing here
claims otherwise. `dist/` itself may be a link (the check is relative to what it resolves to). On a
case-insensitive macOS volume a differently-cased spelling of `dist/` is accepted because `realpath` returns the
on-disk case; on a case-sensitive volume it is another directory and is refused.

Windows has no skipped case. `tests/scripts/release-manifest.sh` sets `MSYS=winsymlinks:nativestrict` (without it
Git Bash's `ln -s` copies, which is how the first Windows run never reached the containment code), asserts
`[ -L ]` after every link, creates a junction with `cmd /c mklink /J` run with MSYS path conversion off (`MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1`, PowerShell `New-Item -ItemType Junction` as the fallback), and fails with "could not create a
symlink: containment unproven on this runner" when a link cannot be made. On macOS and Linux the cases that need
Windows print "not applicable on <os>" and the path rules are covered by the `path.win32` unit tests instead. Windows per-directory case sensitivity (`fsutil file setCaseSensitiveInfo`) is handled since Sprint 6 (S1-106): containment also requires an exact-case prefix test after `realpath.native`, so `DIST` next to `dist` is another directory and is refused (`WINDOWS-OUT.md`, tested on a `path.win32` model with a case-sensitive volume; no real case-sensitive NTFS directory has been tried). `COM0` and `LPT0` are reserved names as well (T2-NOTE-COM0). The CI leg that
proves all of this on a real Windows volume is `fmt, clippy, test (windows-latest)`; until the owner has pushed
and read that run, the Windows rules are tested only against a model of Windows.

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
   script does yet, so leave those "not measured". Do not time `pagetriage.exe` on
   `tests\golden\inputs\blank_speckle.pgm`: that is a process start on a tiny image, not an A4 page.
3. Peak memory: no memory tool exists in this repository. Open Task Manager, Details tab, add the
   "Peak working set (memory)" column, and read it for `python.exe` during the `quality_synth_eval.py`
   run and for the Chrome tab process during the browser run. Write the figure and where it came from.
4. Browser (WebAssembly): `scripts/install-wasm-tools.sh`, then `PAGETRIAGE_WASM_FEATURES=pdf scripts/build-wasm.sh`
   and `scripts/build-site.sh` (Git Bash), serve `site/` locally, turn Wi-Fi off, open it in Chrome and
   analyse the eight sample pages. Time them with DevTools, Performance, and record the numbers.
5. Keep the raw output in the repository, under `docs/benchmarks/`, with its date, commit and machine: run the measurement through
   `python -I bench/record.py --out docs/benchmarks/eval-quality-time-8gb.json --eight-gb "measured on 8 GB: <the machine of step 1>" -- python -I bench/quality_synth_eval.py --only time`
   (the flag is the only way a record can say it was measured on an 8 GB laptop), add its row to [docs/benchmarks/README.md](benchmarks/README.md), and add the figures to
   `docs/benchmarks/claims.json`. Then put the results in the README Benchmarks table (the "8 GB Windows no-GPU laptop" column of the speed row and
   the in-browser row), citing that file, and change the Status line of row 2 to Done in this file. `tests/scripts/benchmarks.sh` fails for a figure that has no committed row.

**Row 4, signed artifacts and manifest.**

Owner must: on the offline key machine (not this Mac, not CI), create the key with `cp-sign keygen`, commit its public key to `docs/release-keys.json`, set
`RELEASE_KEY_ID`, check the candidate files of the publish run, make and sign the manifest with `cp-sign sign --no-expiry`, and attach it to the GitHub release: steps 3, 4, 6, 12, 13
and 14 of [RELEASING.md](RELEASING.md), each with its commands. Never use `--allow-test-key` or `--trust-test-key` for a release: the verifier refuses the test key without them, and a release id is never signed with it.

**Row 5, CHANGELOG and semver tag.**

Owner must: after rows 2, 4, 6 and 7 are as far along as they can be and CI is green on the tag commit, make the tag commit (the only change to 1.0.0: [RELEASING.md](RELEASING.md), step 7) and tag it (step 10).
`git tag v1.0.0` is run by the owner only.

**Row 6, installable from a clean machine.**

Owner must: reserve the names (due 22 Nov 2026: npm `@airplanemode/pagetriage`, PyPI `pagetriage`, crates.io `pagetriage-core` and `pagetriage-cli`), dispatch and approve the publish workflow, and then, on a machine that has
never seen this repository, with Wi-Fi on, run the commands in the block headed "After the owner publishes" below and record the output ([RELEASING.md](RELEASING.md), steps 2, 8 to 11, 14 to 17). Then change the README
Install section so those commands move into the main text, and mark row 6 Done with the recorded output as evidence.

**After the owner publishes** (these registry commands do not work today):

```sh
python3 -m venv v && v/bin/pip install pagetriage==X.Y.Z && v/bin/python -I -c "import pagetriage_py; print(len(pagetriage_py.schema_json()))"
mkdir t && cd t && npm init -y && npm i @airplanemode/pagetriage@X.Y.Z && node -e 'console.log(require("@airplanemode/pagetriage").version())'
cargo install pagetriage-cli --locked && pagetriage --version
```

**Row 7, short write-up.**

Owner must: when row 2 has numbers, finish [writeup-1.0-draft.md](writeup-1.0-draft.md):
replace each "not measured" with the measured figure and its evidence path, remove the "Draft, not
published" heading, publish it (the demo page is its natural home), and mark row 7 Done.

**Row 1, after the push.**

Owner must: `git push`, then read the CI run for the pushed commit on
`ubuntu-latest`, `macos-latest` and `windows-latest` (`gh run list --repo AirplaneMode-Labs/pagetriage`),
and change row 1's status to Done only when all three are green.

## Tag procedure (owner only)

The tag commit, the tag, the publish workflow and everything around them are in [RELEASING.md](RELEASING.md), in order, each step with its commands and the reason the team cannot do it. Do not tag until every
Blocker-for-tag row above is as it must be. The old procedure that stood here (bump, gate, tag, `cargo publish`, `twine upload`, `npm publish`, sign) is replaced by the publish workflow, which publishes only from
files the owner's signed manifest lists, so that nothing is published unsigned.

## Sprint 7: what only CI can prove

The Mac that develops this repository cannot run Linux or Windows. These jobs are written, were read line by line and tested statically (`tests/scripts/ci-policy.sh`), and have not run; the main session reads them after its push, and the
exact log text to look for is in the lane's push list:

| Job (run by CI after the push) | What it proves | Text to look for in its log |
|---|---|---|
| `release-rehearsal (ubuntu-latest)`, `(macos-latest)`, `(windows-latest)` | the npm tarball and the wheel install into an empty project or fresh venv and make one real call; on Linux the sdist builds `--locked` and a wheel built from it does the same; the command-line tool builds from the packaged crates with no registry (on every OS); two `cargo package` runs (one with `--no-verify`, as the publish job runs it) give identical bytes; every `.crate` holds the licence texts and a NOTICE; the TEST-key rehearsal signs, verifies and refuses without the flag; the README quick start runs from the built files; the publish dry run | `cli path:` under the runner temp directory and not under the checkout; `ok: pagetriage-core v1.0.0-rc.1 was compiled from pagetriage-core-1.0.0-rc.1.crate`; no line `Downloaded pagetriage-core`; `crate reproducibility: identical bytes in two runs` and `the --no-verify bytes equal the verified bytes`; `pagetriage-core-1.0.0-rc.1 holds LICENSE-APACHE, LICENSE-MIT, NOTICE` from the gate; `proved: no-flag -> exit 3, 'refused: test_key_refused'`; `rehearsal signed with the test key and verified: 10 proofs`; `pagetriage-core-1.0.0-rc.1.crate: OK` from `sha256sum -c`; `gate ok`; `publish dry run ok: nothing was uploaded` |
| `fmt, clippy, test (windows-latest)`, `(ubuntu-latest)`, `(macos-latest)` | `tests/scripts/run-all.sh`, including the vendored release vectors, the vendored tool's hash after a checkout, the quick-start harness, the publish guard and the workflow policy | `release-tool-vendored.sh`: `every case agrees`; `quickstart.sh`: `43 passed, 0 failed`; `publish-guard.sh`: `117 passed, 0 failed`; `ci-policy.sh`: `0 failed` |

`publish.yml` has no job that runs before the owner dispatches it; `gh run list --workflow publish.yml` shows no run, and nobody on the team runs it.
