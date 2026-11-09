# Changelog

## [Unreleased]

To be released as 1.0.0 when every Blocker-for-tag row in [docs/release.md](docs/release.md) is Done.
The workspace version stays 0.1.0 until then; the bump is the first step of the tag procedure.

### Added

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
