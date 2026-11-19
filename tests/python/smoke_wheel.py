#!/usr/bin/env python3
"""One real call per entry point of an installed pagetriage wheel (the CI wheels job runs this in a fresh venv, no index).

    python -I tests/python/smoke_wheel.py

Reads the synthetic golden inputs of this checkout (tests/golden) and exits 1 unless the installed module gives the
byte-identical structure report of a golden PDF, flags a font-bomb seed as `font_over_limit`, and analyses a blank page.
"""
import json
import pathlib
import sys

import pagetriage_py

GOLDEN = pathlib.Path(__file__).resolve().parents[1] / "golden"


def main():
    pdf = (GOLDEN / "pdf" / "native_latin.pdf").read_bytes()
    want = (GOLDEN / "pdf_expected" / "native_latin.json").read_text(encoding="utf-8")
    same = pagetriage_py.analyse_pdf_structure(pdf) + "\n" == want
    print("structure report of native_latin.pdf is byte-equal to the golden:", same)

    seed = (GOLDEN / "streams_inputs" / "seed_font_bomb.pdf").read_bytes()
    report = json.loads(pagetriage_py.account_pdf_streams(seed))
    print("stream accounting of the font-bomb seed:", report["verdict"], report["reason"])

    blank = json.loads(pagetriage_py.analyse_page(bytes([255]) * (64 * 64), 64, 64))
    found = any(f["kind"] == "blank_page" for f in blank["findings"])
    print("a white page is found blank:", found)

    ok = same and report["reason"] == "font_over_limit" and found
    print("wheel smoke:", "ok" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
