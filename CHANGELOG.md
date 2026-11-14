# Changelog

## [Unreleased]

To be released as 1.0.0 when every Blocker-for-tag row in [docs/release.md](docs/release.md) is Done.
The workspace version stays 0.1.0 until then; the bump is the first step of the tag procedure.

### Added

- Sprint 2: Windows arm of `scripts/install-wasm-tools.sh` (x86_64 wasm-bindgen and binaryen
  release assets, SHA-256 digests pinned in the script, unknown asset names exit non-zero), and
  `windows-latest` in the determinism job of `ci.yml`, with `scripts/determinism.sh` selecting the
  venv `Scripts/` directory. Configured, not yet executed (D2-01, D2-02).
- Sprint 2: a `deny` CI job running cargo-deny 0.20.2 from a SHA-256-pinned binary (no Docker
  action) against the new `deny.toml` licence policy (the eight policy licences plus
  `Apache-2.0 WITH LLVM-exception`); the advisories leg does not block (D2-05, BUG-T2-S2-05).
- Sprint 2: `site/pkg/build.json` carries the build commit (first 12 characters of `GITHUB_SHA` only
  when it is 40 lowercase hex, else `local`) and the demo status line shows it (D2-03).
- Sprint 2: shell tests under `tests/scripts/` (installer: unknown asset, Windows arm64 and the eight
  digest rows, with `curl` and `uname` stubbed; build commit validation; `WASM_OUT` guard), run by the
  `rust` job in `ci.yml` (BUG-T2-S2-03, BUG-T2-S2-08).

- Sprint 3: `scripts/release-manifest.mjs` (Node 22, no dependencies) writes an unsigned
  `airplanemode.manifest/0.1` listing release artifacts with their SHA-256 and size. It has no signing
  option and never reads a key, refuses a `SOURCE_DATE_EPOCH` outside 0..253402300799 and any `--out`
  that does not resolve inside `dist/` (symlinks resolved), and is tested by
  `tests/scripts/release-manifest.sh`, now part of `tests/scripts/run-all.sh` (D2-02, release row 4).
- Sprint 3: `scripts/prove-install.sh` installs the locally built wheel into a `python3 -m venv` (pip
  `--no-index --no-deps`) and a `uv venv` (`--offline`), and the `npm pack` tarball into a fresh empty
  directory (`--ignore-scripts --offline`, empty cache), runs a real analysis in each, requires output
  byte-equal to a golden report, and checks the archives (licence files, no test data, source maps,
  lifecycle scripts or files over 5 MB, the "Not published yet" sentence) (D2-01, release row 6).
- Sprint 3: `docs/writeup-1.0-draft.md`, marked "Draft, not published", built from existing evidence
  only, with the 8 GB figures reading "not measured" (D2-03, release row 7).
- Sprint 3: the demo page shows a Sprint 3 status line and a refreshed "What this demo does not do yet"
  box (D2-04).

- Sprint 3 fix round: `LICENSE-MIT` and `LICENSE-APACHE` copied into `crates/pagetriage-core` and `crates/pagetriage-cli` so each crate tarball carries them, with `tests/scripts/crate-licences.sh` requiring byte equality with the root files (BUG-T2-S3-05).
- Sprint 3 fix round: `scripts/remap-flags.sh` (appends `--remap-path-prefix` for the cargo home, rustup home and repository root to `RUSTFLAGS`, used by `scripts/build-wasm.sh` and the wheel build commands) and `scripts/check-no-builder-paths.sh`, which fails if a wheel or tarball contains `/Users/`, `/home/` or `/private/tmp`; `prove-install.sh` and `package-npm.sh` run it; test `tests/scripts/path-leak-gate.sh` (BUG-T2-S3-03, T3-S3-008).

- Sprint 4: `scripts/gen-site-notice.mjs --py` regenerates the root `NOTICE` from `cargo tree --locked -p pagetriage-py`
  and `cargo metadata --locked`, and `tests/scripts/build-site-notices.sh` (in `run-all.sh`) fails when a block, the upstream SHA
  or a BSD crate name is removed from the root, served or wheel `NOTICE`.
- Sprint 4: the demo page shows a Sprint 4 status line and a refreshed "What this demo does not do yet" box (D2-03).

### Changed

- Sprint 4: `scripts/package-python.sh` sources `scripts/remap-flags.sh`, so a wheel built by it holds no
  builder path (the Sprint 3 proof used the same flags by hand).

- Windows CI is no longer described as "configured, not yet executed": the determinism gate first passed on
  `windows-latest` on 9 Nov 2026, so `docs/release.md` row 1 is Done and the README, demo page and script
  comments say so; the WASM determinism runners use `path.basename` so golden names resolve on Windows.
- Sprint 2: `scripts/install-wasm-tools.sh` looks up both pinned digests before the first download,
  so an unknown wasm-bindgen or binaryen asset exits 1 with no network call and nothing installed
  (BUG-T2-S2-04). `docs/release.md` row 1 cites `evidence/sprint-1/D2/gate.log` (BUG-T2-S2-06).

- Sprint 3: README Install now has "From source", "From locally built artifacts" (the exact offline
  wheel and tarball commands, the proven platform tag `macosx_11_0_arm64`, the statement that Linux and
  Windows wheels are not built yet) and "After the owner publishes" (the bare registry commands); the
  "Not published yet" sentence ships inside the wheel and the npm tarball because both carry this README
  (D2-01). Nothing is published, tagged or reserved; the version is still 0.1.0.
- Sprint 3: `docs/release.md` rewritten for 14 Nov 2026: one row per definition-of-done item with
  evidence paths, an "Owner must" section with the commands for every Open row (the 8 GB Windows
  procedure, signing, tag, install from a registry, write-up), and row 1 reworded because no CI run covers
  the Sprint 3 changes until the owner pushes. Rows 2, 4, 5, 6 and 7 stay Open (D2-03).
- Sprint 3: README WebAssembly size corrected from 246 KB to 479 KB gzipped (855 KB with the PDF parser),
  as measured by `scripts/check-wasm-size.sh` on 14 Nov 2026; both are inside the 1,000,000-byte budget (D2-04).
- Sprint 3: `docs/RELEASING.md` gains "Signing the manifest" and the install-proof script in the checks
  table (D2-02).

- The repository moved from its original personal-account home to `AirplaneMode-Labs/pagetriage`; every URL,
  badge and the GitHub Pages address (`https://airplanemode-labs.github.io/pagetriage/`) now point at
  the organisation. No behaviour change; no golden file changed.
- CI: every action pinned by commit SHA, every job declares its own permissions, Windows added to the
  fmt/clippy/test matrix, the packaging dry runs added as a CI job, Dependabot configured for cargo and
  GitHub Actions. The determinism job stays on Linux and macOS ([docs/release.md](docs/release.md)
  says why).
- README: Install, Benchmarks, Limitations and Security and privacy sections; Apple-silicon figures
  labelled as placeholders with the 8 GB Windows laptop marked not measured.
- Demo page gains CSP, browser-requirements and not-yet boxes; CI builds the demo site; wasm tool
  installer pins release digests.

- Sprint 3 fix round: README Benchmarks drops the unbacked full-page medians (68, 76, 88 ms) and thread-pool throughput (13 to 129 pages/s) and the 13,000-page extrapolation built on them; the speed row is now the quality pass on one synthetic A4 page at 150 dpi (`bench/quality_synth_eval.py --only time`, median 62.7 ms, `evidence/sprint-3/D2/bench-quality-time.log`), a column "8 GB Windows no-GPU laptop" reads "not measured" on every row, and the Limitations say full-page time and throughput are not measured by a repo script yet (Sprint 4). `docs/release.md` row 2 says what each command measures and drops the PowerShell `Measure-Command` line; the demo page speed row says the same (BUG-T2-S3-04).
- Sprint 3 fix round: the README Install sentence is one plain line and `scripts/prove-install.sh` asserts it in full; `docs/release.md` begins each Open row's instructions with `Owner must:` and moves the registry commands into an "After the owner publishes" block; the wheel classifier is `Operating System :: MacOS` until Linux and Windows wheels exist (BUG-T2-S3-06, T3-S3-012).

### Fixed

- BUG-T1-S3-R2-02, BUG-T2-S3-20-R2, TD-03, TD-28: the demo `NOTICE.txt` and the root `NOTICE` carry, for every crate whose
  `cargo metadata --locked` licence is exactly `MIT` (the WASM tree, and the `pagetriage-py` tree that the wheel ships),
  the name, version, copyright line (or the `Cargo.toml` author where the licence file has none) and the full MIT
  text (evidence/sprint-4/D2/red-D2-01.log, green-D2-01.log, mutation-D2-01.log, red-fix1-D2-notice.log, green-fix1-D2-notice.log).
- S1-082, S1-090a: the Python wheel carries `NOTICE` (`license-files` in `crates/pagetriage-py/pyproject.toml`, with a
  copy of the root file in that crate, checked by the same test), now including the MIT blocks
  (evidence/sprint-4/D2/wheel-listing.log).
- BUG-T2-S4-08: the `NOTICE` names brotli-decompressor 5.0.3 (BSD-3-Clause/MIT, Copyright (c) 2016 Dropbox, Inc.) beside
  the alloc crates, and the test checks the served `NOTICE.txt` for the upstream SHA and the BSD crates.
- S1-085: reworded a domain-specific example in a params comment to a neutral one; golden diff empty and params output
  identical (evidence/sprint-4/D2/golden-diff.log, params-diff.log). Attribution trailers in already-pushed history
  are left as they are (docs/release.md, History).
- TD-04: the `NOTICE` alloc-stdlib paragraph states its sources: `Cargo.toml` names BSD-3-Clause, author Daniel Reiter
  Horn and the dropbox/rust-alloc-no-stdlib repository, whose root `LICENSE` was read at upstream commit
  3b341ccfa783a136449eef7dcf4f818f81c077f1 (evidence/sprint-4/D2/upstream-licence.log).
- BUG-T2-S4-06, BUG-T3-S4-02, S1-093: every `cargo` and `maturin` invocation in `ci.yml` and `scripts/` uses `--locked`;
  `maturin` is pinned to 1.16.0 in `package-python.sh` and `determinism.sh` (version only, listed as known gaps in
  docs/release.md).

- BUG-T2-S3-13: removed the unbacked large-document time and memory figures from the README (measured
  ad hoc in Sprint 1, no repo script); a bench script is a Sprint 4 item.
- BUG-T2-S3-12: `docs/release.md` row 6 states the current `cargo package` file counts and cites lists
  regenerated after the licence copies; row 2 gets its full stop.
- T3-S3-023: `scripts/build-site.sh` copies `NOTICE`, `LICENSE-MIT` and `LICENSE-APACHE` into the served
  demo (as `.txt`), the page footer links them, and `NOTICE` now carries the BSD-3-Clause and Unicode-3.0
  texts of the compiled crates that are not offered under MIT or Apache-2.0 alone.
- T3-S3-021: wheel and npm tarball rebuilt after the last README edit, so the packaged README equals
  the repo README.

### Security

- Sprint 3: the dry-run signature of the release manifest used the public RFC 8032 test key through
  `cp-sign --allow-test-key`, verified, and was refused without the flag; the signed file and all keys
  stayed outside the repository, and the release script cannot sign (D2-02).

- Sprint 2: `persist-credentials: false` on every checkout in `stats.yml` and `codeql.yml`;
  `stats.yml` is split into a read-only `snapshot` job and a `push` job that runs no repository
  script and gives the token only to the push step, as a masked header (BUG-S1-D-01, S1-047).
- Sprint 2: `scripts/build-wasm.sh` refuses (exit 2) a `WASM_OUT` that is set but empty, absolute or
  contains a `..` segment before its `rm -rf`; `scripts/package-npm.sh` removes only the fixed
  `dist/npm` and needed no change (BUG-T2-S2-08).
- Sprint 2: the `WASM_OUT` guard in `scripts/build-wasm.sh` also refuses (exit 2) a Windows drive-letter
  path (`C:/x`, `C:x`) and any value containing a backslash (`..\x`, `a\..\b`, `dist\ok`), before cargo
  and before `rm -rf`; cases added to `tests/scripts/build-wasm-guard.sh` (BUG-T2-S2-14).

- Deterministic page analysis for scanned documents and PDFs, with one Rust core compiled to three
  runtimes: native (`pagetriage-cli`), Python (`pagetriage-py`, PyO3, abi3) and WebAssembly
  (`pagetriage-wasm`, wasm-bindgen, browser and Node). The same input gives the same report bytes on
  all three.
- Modules M1 to M14 ([docs/modules.md](docs/modules.md)): text layer (M1), font script (M2), scan
  quality with skew, blur, contrast, specks, bleed-through, folds and binariser choice (M3), script
  from pixels (M4), handwriting (M5), stamps and seals (M6), signatures (M7), thumb impressions (M8),
  rulings (M9), page and region typing (M10), Indian-deed detectors (M11), provenance and
  near-duplicate hashes (M12), fusion and calibration machinery (M13) and the page plan with
  `pagetriage prepare` (M14). Detectors from M4 on are opt-in.
- Four binarisers: Otsu, Sauvola, Wolf-Jolion and Howe (static mode), with the DIBCO benchmark
  harness in `bench/`.
- The determinism gate (`scripts/determinism.sh`): golden inputs must give byte-identical reports on
  native, Python and WASM, on Linux and macOS, and the WASM build must stay inside its gzip size
  budget.
- Command-line tool (`analyse`, `structure`, `duplicates`, `prepare`, `schema`, `params`), a JSON
  Schema for the report, thresholds in readable TOML under `crates/pagetriage-core/params/`.
- Browser demo (`site/`) running the WASM build in the tab with nothing uploaded, deployed by the
  `pages` workflow only when the WASM build reproduces the native fingerprints.
- Packaging dry runs for the npm tarball, the Python wheel and the core crate
  ([docs/RELEASING.md](docs/RELEASING.md)); nothing is published.

- NOTICE and SECURITY.md added (90-day coordinated disclosure, no telemetry, no key material in this
  repository).
- The `stats` workflow no longer references a repository secret; it runs with the workflow token only.

- Sprint 3 fix round: the wheel no longer embeds the Rust CycloneDX SBOM (`sbom = { rust = false }` in `pyproject.toml`), which recorded the builder's absolute checkout path; compiler path strings are remapped (BUG-T2-S3-03).

### What a release does not claim

Every detector from module M4 on was checked on synthetic pages only, and no confidence is calibrated
([docs/detectors/fusion.md](docs/detectors/fusion.md)). A release note should say so in the same words.

---

All notable changes to pagetriage are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).
