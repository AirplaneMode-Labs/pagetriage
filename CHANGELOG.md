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

### Changed

- Sprint 2: `scripts/install-wasm-tools.sh` looks up both pinned digests before the first download,
  so an unknown wasm-bindgen or binaryen asset exits 1 with no network call and nothing installed
  (BUG-T2-S2-04). `docs/release.md` row 1 cites `evidence/sprint-1/D2/gate.log` (BUG-T2-S2-06).

### Security

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

### Changed

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

### Security

- NOTICE and SECURITY.md added (90-day coordinated disclosure, no telemetry, no key material in this
  repository).
- The `stats` workflow no longer references a repository secret; it runs with the workflow token only.

### What a release does not claim

Every detector from module M4 on was checked on synthetic pages only, and no confidence is calibrated
([docs/detectors/fusion.md](docs/detectors/fusion.md)). A release note should say so in the same words.

---

All notable changes to pagetriage are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).
