#!/usr/bin/env python3
"""Run the stream-accounting inputs through the Python binding and require byte-identical reports.

The inputs are the structure goldens (tests/golden/pdf) and the small synthetic bomb seeds
(tests/golden/streams_inputs); the expected bytes are tests/golden/streams. Needs `pagetriage_py`
installed (scripts/determinism.sh does `maturin develop`). Run with `-I`.
"""
import hashlib
import json
import pathlib
import sys

import pagetriage_py

GOLDEN = pathlib.Path(__file__).resolve().parents[1] / "golden"


def main():
    inputs = sorted(list((GOLDEN / "pdf").glob("*.pdf")) + list((GOLDEN / "streams_inputs").glob("*.pdf")), key=lambda p: p.stem)
    if len(inputs) < 14:
        sys.exit(f"expected the 8 structure PDFs and at least 6 seeds, found {len(inputs)}")

    failures = 0
    for path in inputs:
        actual = pagetriage_py.account_pdf_streams(path.read_bytes()) + "\n"
        expected = (GOLDEN / "streams" / f"{path.stem}.json").read_text(encoding="utf-8")
        digest = hashlib.sha256(actual.encode()).hexdigest()[:16]
        if actual == expected:
            print(f"ok   python {path.stem:<24} sha256={digest}")
        else:
            failures += 1
            at = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b), min(len(actual), len(expected)))
            print(f"FAIL python {path.stem}: first difference at byte {at}")
            print(f"  actual  : ...{actual[max(0, at - 30) : at + 40]!r}")
            print(f"  expected: ...{expected[max(0, at - 30) : at + 40]!r}")

    # not a PDF is a refusal with a reason, not an exception
    report = json.loads(pagetriage_py.account_pdf_streams(b"definitely not a pdf", None))
    if report["verdict"] == "refuse" and report["reason"] == "unaccounted":
        print("ok   python non-PDF input is refused as unaccounted")
    else:
        failures += 1
        print(f"FAIL python: non-PDF input gave {report['verdict']} {report['reason']}")

    # options can lower a limit and cannot raise one
    seed = (GOLDEN / "streams_inputs" / "seed_font_bomb.pdf").read_bytes()
    raised = json.loads(pagetriage_py.account_pdf_streams(seed, json.dumps({"params": "font_decoded_max = 99999999999"})))
    lowered = json.loads(pagetriage_py.account_pdf_streams(seed, json.dumps({"params": "font_decoded_max = 1000"})))
    if raised["limits"]["font_decoded_max"] == 33554432 and lowered["limits"]["font_decoded_max"] == 1000:
        print("ok   python options lower a limit and cannot raise one")
    else:
        failures += 1
        print(f"FAIL python: limits {raised['limits']['font_decoded_max']} / {lowered['limits']['font_decoded_max']}")

    # bad options are a ValueError
    try:
        pagetriage_py.account_pdf_streams(seed, '{"nope": 1}')
    except ValueError:
        print("ok   python bad options raise ValueError")
    else:
        failures += 1
        print("FAIL python: bad options did not raise")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
