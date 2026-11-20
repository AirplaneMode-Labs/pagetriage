#!/usr/bin/env bash
# Re-runs the accuracy and behaviour evaluations whose figures docs/detectors/ and the README quote, and keeps what each one
# printed under docs/benchmarks/ with its date, commit, machine and command (bench/record.py). Nothing is edited by hand.
#
#   bench/record_all.sh synthetic     every evaluation that needs no download (a few minutes in all)
#   bench/record_all.sh dibco         the evaluations over the DIBCO pages (needs `python -I bench/fetch.py` first; about 30 minutes,
#                                      the Howe dual run is most of it)
#   bench/record_all.sh structure     the synthetic PDF corpus: our scores, and pdf-inspector's beside them
#   bench/record_all.sh sizes         builds both WebAssembly packages and the release artefacts (scripts/release/rehearse.sh build) and
#                                      records their sizes; needs the tools of scripts/install-wasm-tools.sh on PATH
#
# Run it from a Python environment that has numpy, Pillow, qrcode and augraphy and the pagetriage_py binding built with
# `maturin develop --release -m crates/pagetriage-py/Cargo.toml`; `cargo build --release -p pagetriage-cli` for the CLI-driven ones.
# `hero-figure` regenerates docs/img/hero.png (the picture is deterministic; check `git diff --stat docs/img`).
# The speed, large-document and stream-accounting CSV files are not made here: they have their own commands, listed with every
# other file in docs/benchmarks/README.md. Run the groups one after the other, never in parallel, so the timings in the output
# are not disturbed. None of the output is from an 8 GB laptop.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=docs/benchmarks
PY=${PYTHON:-python}
rc=0

rec() { # rec NAME -- command...
  local name=$1; shift; shift
  "$PY" -I bench/record.py --out "$OUT/eval-$name.json" -- "$@" || rc=1
}

synthetic() {
  rec quality-synth   -- python -I bench/quality_synth_eval.py
  rec quality-time    -- python -I bench/quality_synth_eval.py --only time
  rec quality-stress  -- python -I bench/quality_stress.py
  rec layout-synth    -- python -I bench/layout_synth_eval.py --seeds 5
  rec script-synth    -- python -I bench/script_synth_eval.py
  rec handwriting-synth -- python -I bench/handwriting_synth_eval.py
  rec rulings-synth   -- python -I bench/rulings_synth_eval.py
  rec stamp-synth     -- python -I bench/stamp_synth_eval.py
  rec signature-synth -- python -I bench/signature_synth_eval.py
  rec thumb-synth     -- python -I bench/thumb_synth_eval.py
  rec redaction-synth -- python -I bench/redaction_synth_eval.py
  rec photo-synth     -- python -I bench/photo_synth_eval.py
  rec coverage-synth  -- python -I bench/coverage_synth_eval.py
  rec page-type-synth -- python -I bench/page_type_synth_eval.py
  rec emboss-synth    -- python -I bench/emboss_synth_eval.py
  rec orientation-synth -- python -I bench/orientation_synth_eval.py
  rec plan-synth      -- python -I bench/plan_synth_eval.py
  rec qr-synth        -- python -I bench/qr_synth_eval.py
  rec page-size       -- python -I bench/page_size_eval.py
  rec prepare-synth   -- python -I bench/prepare_synth_eval.py
  rec legacy-probe-1  -- python -I bench/tools/legacy_probe.py 1
  rec legacy-probe-3  -- python -I bench/tools/legacy_probe.py 3
  rec hero-figure     -- python -I docs/img/make_figure.py
}

structure() {
  [ -d bench/data/synth_pdf ] || python -I bench/synth/make_pdf_corpus.py || rc=1
  rec structure-all      -- python -I bench/structure_eval.py --corpus bench/data/synth_pdf --split all
  rec structure-dev      -- python -I bench/structure_eval.py --corpus bench/data/synth_pdf --split dev
  rec structure-heldout  -- python -I bench/structure_eval.py --corpus bench/data/synth_pdf --split heldout
  # pdf-inspector's verdicts: a standalone crate (not a workspace member), built into target/ (git-ignored) and copied to a fixed path
  TOOL=${PDF_INSPECTOR_COMPARE:-target/pdf-inspector-compare}
  if [ ! -x "$TOOL" ]; then
    CARGO_TARGET_DIR=target/pdf-inspector cargo build --release --locked --manifest-path bench/tools/pdf_inspector_compare/Cargo.toml \
      && cp target/pdf-inspector/release/pdf-inspector-compare "$TOOL" || { echo "could not build bench/tools/pdf_inspector_compare" >&2; rc=1; return; }
  fi
  rec compare-pdf-inspector -- python -I bench/compare_pdf_inspector.py --corpus bench/data/synth_pdf --split all --tool "$TOOL"
}

sizes() {
  PAGETRIAGE_WASM_FEATURES= WASM_OUT=dist/wasm-pixel bash scripts/build-wasm.sh || rc=1
  PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf bash scripts/build-wasm.sh || rc=1
  REHEARSE_ALLOW_DIRTY=1 REHEARSE_SDIST=1 bash scripts/release/rehearse.sh build || rc=1
  rec sizes -- python -I bench/sizes_report.py --wasm pixel-only=dist/wasm-pixel/web/pagetriage_bg.wasm --wasm pdf=dist/wasm-pdf/web/pagetriage_bg.wasm --dir dist-release
}

dibco() {
  rec binarize-otsu-train -- python -I bench/eval_binarize.py --method otsu --sets dibco2009 dibco2010
  rec binarize-otsu-2011 -- python -I bench/eval_binarize.py --method otsu --sets dibco2011
  rec binarize-sauvola-train -- python -I bench/eval_binarize.py --method sauvola --sets dibco2009 dibco2010
  rec binarize-sauvola-2011 -- python -I bench/eval_binarize.py --method sauvola --sets dibco2011
  rec binarize-wolf-train -- python -I bench/eval_binarize.py --method wolf --sets dibco2009 dibco2010
  rec binarize-wolf-2011 -- python -I bench/eval_binarize.py --method wolf --sets dibco2011
  rec binarize-howe-static-train -- python -I bench/eval_binarize.py --method howe --howe-mode static --sets dibco2009 dibco2010
  rec binarize-howe-static-2011 -- python -I bench/eval_binarize.py --method howe --howe-mode static --sets dibco2011
  rec binarize-howe-tune-c-train -- python -I bench/eval_binarize.py --method howe --howe-mode tune_c --sets dibco2009 dibco2010
  rec binarize-howe-tune-c-2011 -- python -I bench/eval_binarize.py --method howe --howe-mode tune_c --sets dibco2011
  rec binarize-howe-dual-train -- python -I bench/eval_binarize.py --method howe --howe-mode dual --sets dibco2009 dibco2010
  rec binarize-howe-dual-2011 -- python -I bench/eval_binarize.py --method howe --howe-mode dual --sets dibco2011
  rec skew-white          -- python -I bench/skew_eval.py --data bench/data --sets all
  rec skew-paper          -- python -I bench/skew_eval.py --data bench/data --sets all --fill paper
  rec skew-augraphy       -- python -I bench/skew_eval.py --data bench/data --sets all --augraphy
  rec quality-dibco       -- python -I bench/quality_eval.py --data bench/data --table
  rec phash               -- python -I bench/phash_eval.py --data bench/data --synthetic 100
}

case "${1:-}" in
  synthetic) synthetic ;;
  structure) structure ;;
  sizes) sizes ;;
  dibco) dibco ;;
  *) echo "usage: bench/record_all.sh synthetic|structure|sizes|dibco" >&2; exit 2 ;;
esac
exit $rc
