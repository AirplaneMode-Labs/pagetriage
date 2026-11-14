# pagetriage 1.0: what it does and what is measured

**Draft, not published.** Written 14 Nov 2026 for release row 7 of [release.md](release.md). It uses only
evidence that exists today. Every figure names the file it comes from; a figure without a path is not in
this draft. The 8 GB laptop figures read "not measured" because nobody has measured them, and the draft
cannot be finished until [row 2](release.md) closes. Nothing here is published, tagged or announced.

Paths starting with `evidence/sprint-3/D2/` are copied into the repository by the architect at wrap-up;
until then they sit in the Sprint 3 scratch folder.

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

Not published yet: the npm scope `@airplanemode` and the PyPI and crates.io names are not reserved. A wheel
and an npm tarball were built locally and installed offline into fresh environments on macOS arm64,
`evidence/sprint-3/D2/install-all-r2.log`. The wheel is `pagetriage-0.1.0-cp39-abi3-macosx_11_0_arm64.whl`;
Linux and Windows wheels are not built yet. Commands: README, [Install](../README.md#install).

## What it does not do

- It has not been run on a real Indian deed, and no confidence is calibrated
  ([Limitations](../README.md#limitations), `docs/detectors/fusion.md`).
- It does not read text.
- Nothing is signed. `scripts/release-manifest.mjs` writes an unsigned manifest; a dry run with the public
  test key verified, which proves the tooling only (`evidence/sprint-3/D2/dry-run-sign.log`).
- Nothing is published, and no version is tagged. v1.0.0 is held by release rows 2, 4, 5, 6 and 7.

## To finish this draft

Replace each "not measured" with the owner's figure and its evidence path once row 2 is done, remove the
"Draft, not published" heading, and publish it with the tag.
