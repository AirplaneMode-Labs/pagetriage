# pagetriage 1.0: what it does and what is measured

**Draft, not published.** Written 14 Nov 2026 for release row 7 of [release.md](release.md) and refreshed on 20 Nov 2026 (Sprint 7). It uses only
evidence that exists today. Every figure names the file it comes from; a figure without a path is not in
this draft. The 8 GB laptop figures read "not measured on 8 GB" because nobody has measured them, and the draft
cannot be finished until [row 2](release.md) closes. Nothing here is published, tagged or announced; the version is the release candidate
1.0.0-rc.1.

Paths starting with `evidence/sprint-N/D2/` are copied into the repository by the architect at wrap-up;
until then they sit in that sprint's scratch folder.

## What it is

A deterministic, non-ML analyser for scanned legal documents. It tells you, before you spend OCR time or a
model call on a page, whether a PDF has a real text layer, an invisible OCR layer or nothing; whether that
text sits in a legacy font that copies out as Latin gibberish; how degraded the scan is; and whether a page
repeats an earlier one. It does not read text. One Rust core builds to a command-line tool, a Python wheel
and a WebAssembly package. Source: [README](../README.md), [modules](modules.md).

## Same bytes on every runtime

The same input gives the same report bytes on native, Python and WebAssembly. `scripts/determinism.sh`
compares them against golden reports in `tests/golden/`, and on 14 Nov 2026 it exited 0:
`evidence/sprint-3/D2/gates-s3.log`. The Sprint 3 install proofs repeat the comparison from installed
artifacts: a real analysis of `tests/golden/inputs/blank_speckle.pgm` through the installed wheel (in a
`python3 -m venv` and in a `uv venv`) and through the installed npm tarball was byte-equal to
`tests/golden/expected/blank_speckle.json` each time (sha256 prefix f38773d4f7078659 in all three):
`evidence/sprint-3/D2/install-all-r2.log`.

## What was measured

All of these come from [docs/detectors/](detectors/) and were measured before Sprint 3; none was re-measured
for this draft. The corpora are synthetic or public benchmark sets, not real deeds.

| What | Result | Where | Caveat |
|---|---|---|---|
| PDF text-layer state, 300 synthetic pages | 300 of 300 correct | `docs/detectors/text_layer.md` | We wrote the corpus; weak evidence for real PDFs |
| Howe binarisation, DIBCO 2011, held out | F-measure 89.59, paper 91.90 | `docs/detectors/binarize.md` | Misses our own target by 2.1 points |
| Howe binarisation, training sets (20 images) | F-measure 94.01, paper 93.84 | `docs/detectors/binarize.md` | Conventions were chosen on these images |
| Quality-pass time per page, 136 DIBCO pages (0.05 to 9 MP), Python call | median 29 ms, 90th percentile 79 ms | `docs/detectors/quality.md` | Apple-silicon development machine |
| Quality pass on one synthetic A4 page at 150 dpi, Python call (`bench/quality_synth_eval.py --only time`) | median 62.7 ms | `evidence/sprint-3/D2/bench-quality-time.log` | Apple-silicon development machine; one page, quality pass only. Full-page analysis time and thread-pool throughput are not measured by a repo script yet (Sprint 4) |
| WebAssembly size, gzip -9, without / with the PDF parser | 478,548 / 855,021 bytes | `evidence/sprint-3/D2/wasm-size.log` | Budget 1,000,000 bytes |
| Rust tests | 419 passed | `evidence/sprint-3/D2/gates-s3.log` | macOS arm64 |

## On the 8 GB Windows laptop without a GPU

| What | Result |
|---|---|
| Analysis time per A4 page at 150 dpi, native | not measured |
| Peak memory of an analysis | not measured |
| In-browser (WebAssembly) time per page | not measured |

The procedure is in [release.md](release.md), "Owner must", row 2.

## Install, today

Not published yet: the npm scope `@airplanemode` and the PyPI and crates.io names are not reserved. The package names are `@airplanemode/pagetriage`, `pagetriage`, `pagetriage-core` and `pagetriage-cli`; they are placeholders.
The wheel, the npm tarball and the command-line tool were built and installed offline into fresh environments on one macOS arm64 Mac, twice: in Sprint 3 at version 0.1.0
(`evidence/sprint-3/D2/install-all-r2.log`) and in Sprint 7 at 1.0.0-rc.1 (below). Linux and Windows have not run any of it. Commands: README, [Install](../README.md#install).

## Release readiness, Sprint 7 (20 Nov 2026)

What a reader needs to trust a release is that the files that would be published were built the way a release builds them, install on a machine that has nothing else, and are signed by a key that is not a test key.
Sprint 7 built the first two and the tooling for the third; the key is the owner's.

- **Built as a release builds them, installed from the built files.** `scripts/release/rehearse.sh` builds the npm tarball (1,833,534 bytes), the wheel (1,776,831 bytes), the sdist (458,602 bytes) and the two crates (376,319 and 46,883 bytes),
  installs the tarball into an empty project and the wheel into a fresh venv with the network off, and calls each once on a synthetic golden page and a synthetic golden PDF: the output was byte-equal to the golden report each time. A wheel built
  from the sdist alone passed the same check, and the command-line tool was built from the two packaged `.crate` files with every other crate from a vendored directory and no registry
  (`evidence/sprint-7/D2/green/D2-02-rehearse-all-nosiblings-final.log`, run in a copy of the repository with no sibling repository). One Mac ran it; the CI job that runs it on Linux, macOS and Windows has not run on a runner.
- **The crates are reproducible on that Mac**: two `cargo package --locked` runs gave identical `.crate` bytes (`crate reproducibility: identical bytes in two runs (macos)`, same log), and so did the `--no-verify` run that the publish job repeats (`evidence/sprint-7/D2/green/FR1-rehearse-all-nosiblings-1.log`, "the --no-verify bytes equal the verified bytes"), which is what lets them stay in the signed set. Each crate carries `LICENSE-APACHE`, `LICENSE-MIT` and a `NOTICE` (the rehearsal's gate checks the three inside every `.crate`).
- **A rehearsal signature that cannot be mistaken for a release.** The same run made `release-manifest.json` and `SHA256SUMS`, signed them with the published RFC 8032 test key, and showed ten refusals, each by exit code and first line of stderr:
  the same files without the explicit flag (`refused: test_key_refused`), against the committed production key file, which holds no key (`refused: no_trusted_key`), with no expected id, with a release id, with a trust file together with the flag, with a wrong id,
  with one byte flipped, with CRLF line endings in `SHA256SUMS`, and the test key asked to sign a `-release` id (`usage: test_key_release_id`). Two runs with the same `SOURCE_DATE_EPOCH` wrote byte-identical files
  (`evidence/sprint-7/D2/green/D2-02-rehearse-twice-identical-1.log`). The published key proves the tooling and nothing else.
- **Publishing cannot happen by accident.** `.github/workflows/publish.yml` starts only by a dispatch on `main`, waits for the owner's approval in a protected environment, verifies the owner's signed manifest against a key committed in the repository (empty today),
  checks that the tag points at the commit and that no registry holds the version, attests the exact files, and only then publishes. Its rules are tested (`tests/scripts/ci-policy.sh`, with 68 deliberate mutations that must turn it red,
  `tests/scripts/ci-policy-mutations.sh`) and so is each refusal of its checks (`tests/scripts/publish-guard.sh`, 117 checks). Nobody has run it. The dry run of its commands found one real defect: `npm publish` needs `./` before a path, or it reads
  it as a GitHub repository name. The owner's steps, in order, are in [RELEASING.md](RELEASING.md).
- **The README example is run by a test.** "Try it in two minutes" builds the three artefacts, installs them into an empty directory and prints `native_text` for a 586-byte synthetic PDF through Node, Python and the command line; breaking any block turns the
  test red (`evidence/sprint-7/D2/green/D2-05-quickstart-broken-blocks-1.log`).
- **Dependencies.** toml 1.2.1 and jsonschema 0.61.2 were applied with the golden reports unchanged on native, Python and WebAssembly; lopdf 0.47.0 was not, because one stream test gets a different refusal reason for a 100 MiB object-stream bomb
  (`evidence/sprint-7/D2/dependabot.md`). The gzipped WebAssembly package is 889,491 bytes with the PDF parser and 478,303 without it (`scripts/check-wasm-size.sh`, budget 1,000,000).

## What it does not do

- It has not been run on a real Indian deed, and no confidence is calibrated
  ([Limitations](../README.md#limitations), `docs/detectors/fusion.md`).
- It does not read text.
- Nothing is signed with a real key. The rehearsal signs with the published test key, which proves the tooling only (`evidence/sprint-7/D2/green/D2-02-rehearse-all-nosiblings-final.log`); `docs/release-keys.json` holds no key.
- Nothing is published, and no version is tagged. v1.0.0 is held by release rows 2, 4, 5, 6 and 7, and every one of them is the owner's ([release.md](release.md)).
- Nothing has been shown to build or install on Linux or Windows, and nothing was measured on an 8 GB laptop (not measured on 8 GB).

## To finish this draft

Replace each "not measured" with the owner's figure and its evidence path once row 2 is done, remove the
"Draft, not published" heading, and publish it with the tag.
