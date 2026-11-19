#!/usr/bin/env python3
"""Tests for tests/python/check_wheel.py (TD-09, the wheels job). Run with -I:

    python3 -I tests/python/test_check_wheel.py          (run by tests/scripts/check-wheel-tags.sh, so by run-all.sh)

CI lesson of 18 Nov 2026 (glyphsift run 44325740893): a manylinux wheel's FILENAME carries a compressed tag set
(PEP 425), `cp39-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64`, and its WHEEL file lists one `Tag:` line per
expanded tag. A plain string compare failed on Linux only. The Mac that develops this repository has no Linux wheel,
so this file builds synthetic wheels (a zip with the files the script reads) and tests the tag comparison as expanded
sets, in every order, plus what the rest of the script checks. The WHEEL texts are the shapes maturin 1.16.0 writes.

CHECK_WHEEL_SCRIPT overrides the script under test (an absolute file path), so the suite can be run against a stub for
the red log; leave it unset otherwise.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("CHECK_WHEEL_SCRIPT") or os.path.join(HERE, "check_wheel.py")
VERSION = "0.1.0"
HEAD = "Wheel-Version: 1.0\nGenerator: maturin (1.16.0)\nRoot-Is-Purelib: false\n"
MIT = "Permission is hereby granted, free of charge, to any person obtaining a copy\nTHE SOFTWARE IS PROVIDED \"AS IS\"\n"


def wheel_text(*tags):
    return HEAD + "".join(f"Tag: {t}\n" for t in tags)


def load():
    spec = importlib.util.spec_from_file_location("check_wheel_under_test", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_wheel(directory, plat, tags, extra=None, notice=None, drop=()):
    name = f"pagetriage-{VERSION}-cp39-abi3-{plat}.whl"
    di = f"pagetriage-{VERSION}.dist-info/"
    files = {
        "pagetriage_py/__init__.py": "from .pagetriage_py import *\n",
        "pagetriage_py/pagetriage_py.abi3.so": "stub extension",
        di + "METADATA": "Metadata-Version: 2.4\nName: pagetriage\nVersion: " + VERSION + "\n",
        di + "WHEEL": wheel_text(*tags),
        di + "licenses/LICENSE-MIT": "MIT",
        di + "licenses/LICENSE-APACHE": "Apache",
        di + "licenses/NOTICE": notice if notice is not None else "Airplane Mode Labs pagetriage\n" + MIT,
    }
    files.update(extra or {})
    for d in drop:
        files.pop(d.replace("{di}", di), None)
    path = os.path.join(directory, name)
    with zipfile.ZipFile(path, "w") as z:
        for n, c in files.items():
            z.writestr(n, c)
    return path


def run(wheel):
    p = subprocess.run([sys.executable, "-I", SCRIPT, wheel, VERSION], capture_output=True, text=True)
    return p.returncode, p.stdout


class TagFunctions(unittest.TestCase):
    def test_expand_a_manylinux_name(self):
        m = load()
        self.assertEqual(
            m.expand_tags("cp39-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64"),
            frozenset({"cp39-abi3-manylinux2014_x86_64", "cp39-abi3-manylinux_2_17_x86_64"}),
        )

    def test_a_dotless_tag_is_itself(self):
        m = load()
        self.assertEqual(m.expand_tags("cp39-abi3-win_amd64"), frozenset({"cp39-abi3-win_amd64"}))

    def test_the_cross_product_of_three_parts(self):
        m = load()
        self.assertEqual(len(m.expand_tags("cp39.cp310-abi3.none-linux_x86_64.manylinux_2_17_x86_64")), 8)

    def test_malformed_tags_are_refused(self):
        m = load()
        for bad in ["cp39-abi3", "cp39-abi3-a-b", "cp39-abi3-", "cp39-abi3-a..b", "cp39-abi3-a b"]:
            with self.assertRaises(ValueError, msg=bad):
                m.expand_tags(bad)

    def test_wheel_file_tags_ignore_other_headers_and_text_that_only_contains_tag(self):
        m = load()
        text = wheel_text("cp39-abi3-macosx_11_0_arm64") + "Build: Tag: cp39-abi3-bogus\nTagged: cp39-abi3-other\n"
        self.assertEqual(m.wheel_file_tags(text), frozenset({"cp39-abi3-macosx_11_0_arm64"}))

    def test_tag_mismatch_compares_sets_in_any_order(self):
        m = load()
        name = "cp39-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64"
        a = wheel_text("cp39-abi3-manylinux2014_x86_64", "cp39-abi3-manylinux_2_17_x86_64")
        b = wheel_text("cp39-abi3-manylinux_2_17_x86_64", "cp39-abi3-manylinux2014_x86_64")  # the other order
        self.assertIsNone(m.tag_mismatch(name, a))
        self.assertIsNone(m.tag_mismatch(name, b))
        self.assertIsNone(m.tag_mismatch("cp39-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64", a), "the name in the other order")

    def test_tag_mismatch_names_a_missing_and_an_extra_tag(self):
        m = load()
        name = "cp39-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64"
        one = m.tag_mismatch(name, wheel_text("cp39-abi3-manylinux2014_x86_64"))
        self.assertIn("in the filename but not in WHEEL", one)
        self.assertIn("manylinux_2_17_x86_64", one)
        extra = m.tag_mismatch("cp39-abi3-win_amd64", wheel_text("cp39-abi3-win_amd64", "cp39-abi3-win32"))
        self.assertIn("in WHEEL but not in the filename", extra)
        self.assertIn("not <python>-<abi>-<platform>", m.tag_mismatch("cp39-abi3", wheel_text("cp39-abi3-win_amd64")))


class WheelEndToEnd(unittest.TestCase):
    def check(self, plat, tags, **kw):
        with tempfile.TemporaryDirectory() as d:
            return run(make_wheel(d, plat, tags, **kw))

    def test_manylinux_wheel_passes(self):
        code, out = self.check("manylinux2014_x86_64.manylinux_2_17_x86_64", ["cp39-abi3-manylinux2014_x86_64", "cp39-abi3-manylinux_2_17_x86_64"])
        self.assertEqual(code, 0, out)
        self.assertIn("WHEEL records the same tag set as the filename", out)

    def test_macos_and_windows_wheels_pass(self):
        for plat in ["macosx_11_0_arm64", "win_amd64"]:
            code, out = self.check(plat, [f"cp39-abi3-{plat}"])
            self.assertEqual(code, 0, out)

    def test_a_missing_tag_line_fails_the_tag_check_only(self):
        code, out = self.check("manylinux2014_x86_64.manylinux_2_17_x86_64", ["cp39-abi3-manylinux2014_x86_64"])
        self.assertEqual(code, 1, out)
        fails = [l for l in out.splitlines() if l.startswith("FAIL")]
        self.assertEqual(len(fails), 1, out)
        self.assertIn("same tag set", fails[0])

    def test_missing_notice_or_mit_text_fails(self):
        code, out = self.check("win_amd64", ["cp39-abi3-win_amd64"], drop=["{di}licenses/NOTICE"])
        self.assertEqual(code, 1, out)
        code, out = self.check("win_amd64", ["cp39-abi3-win_amd64"], notice="no licence text here\n")
        self.assertEqual(code, 1, out)

    def test_entry_points_tests_and_scripts_fail(self):
        di = f"pagetriage-{VERSION}.dist-info/"
        for extra in [{di + "entry_points.txt": "[console_scripts]\nx = y\n"}, {"tests/test_x.py": "x"}, {f"pagetriage-{VERSION}.data/scripts/x": "x"}]:
            code, out = self.check("win_amd64", ["cp39-abi3-win_amd64"], extra=extra)
            self.assertEqual(code, 1, out)

    def test_a_file_over_5_mb_fails(self):
        code, out = self.check("win_amd64", ["cp39-abi3-win_amd64"], extra={"pagetriage_py/big.bin": "x" * (5 * 1024 * 1024 + 1)})
        self.assertEqual(code, 1, out)

    def test_a_wrong_version_or_python_tag_fails(self):
        with tempfile.TemporaryDirectory() as d:
            w = make_wheel(d, "win_amd64", ["cp39-abi3-win_amd64"])
            self.assertEqual(subprocess.run([sys.executable, "-I", SCRIPT, w, "9.9.9"], capture_output=True, text=True).returncode, 1)
            bad = os.path.join(d, f"pagetriage-{VERSION}-cp310-abi3-win_amd64.whl")
            os.rename(w, bad)
            self.assertEqual(run(bad)[0], 1, "an abi3 wheel for cp310 is not the cp39-abi3 wheel the package promises")


if __name__ == "__main__":
    unittest.main(verbosity=1)
