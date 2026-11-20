#!/usr/bin/env python3
"""One real call of an INSTALLED pagetriage wheel, and proof that the installed copy is what ran (TD-106, Sprint 7).

    <venv>/bin/python -I scripts/release/check-installed.py <golden-dir> <venv-dir>

<golden-dir> is tests/golden of the checkout (test data only: the code under test is the wheel). Exits 1 unless
  - pagetriage_py was imported from <venv-dir>/.../site-packages (its __file__ contains '.venv', and sys.prefix is <venv-dir>),
  - analyse_page on the synthetic golden page blank_speckle.pgm returns the golden report byte for byte, and
  - analyse_pdf_structure on the synthetic golden PDF native_latin.pdf returns the golden structure report byte for byte.
Prints the module path, so a log shows where the code came from.
"""
import pathlib
import sys

import pagetriage_py


def read_pgm(path):
    data = path.read_bytes()
    pos, tokens = 0, []
    while len(tokens) < 4:
        while data[pos : pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos : pos + 1].isspace():
            pos += 1
        tokens.append(data[start:pos].decode())
    pos += 1
    assert tokens[0] == "P5" and tokens[3] == "255", f"{path}: unsupported PGM"
    w, h = int(tokens[1]), int(tokens[2])
    pixels = data[pos:]
    assert len(pixels) == w * h, f"{path}: pixel count mismatch"
    return w, h, pixels


def main(argv):
    if len(argv) != 3:
        print("usage: check-installed.py <golden-dir> <venv-dir>", file=sys.stderr)
        return 2
    golden = pathlib.Path(argv[1]).resolve()
    venv = pathlib.Path(argv[2]).resolve()
    module = pathlib.Path(pagetriage_py.__file__).resolve()
    prefix = pathlib.Path(sys.prefix).resolve()
    print("module:", module)
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond

    check(".venv" in module.as_posix(), "the module path contains .venv")
    check(prefix == venv, f"sys.prefix is the fresh venv ({prefix})")
    check(venv in module.parents and "site-packages" in module.parts, "the module sits under <venv>/.../site-packages")

    w, h, gray = read_pgm(golden / "inputs" / "blank_speckle.pgm")
    got = pagetriage_py.analyse_page(gray, w, h, 150, None, None, '{"debug":true}') + "\n"
    want = (golden / "expected" / "blank_speckle.json").read_text(encoding="utf-8")
    check(got == want, "analyse_page on the golden page blank_speckle.pgm is byte-equal to its golden report")

    pdf = (golden / "pdf" / "native_latin.pdf").read_bytes()
    want = (golden / "pdf_expected" / "native_latin.json").read_text(encoding="utf-8")
    check(pagetriage_py.analyse_pdf_structure(pdf) + "\n" == want, "analyse_pdf_structure on the golden PDF native_latin.pdf is byte-equal to its golden report")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
