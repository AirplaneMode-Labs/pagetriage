"""The speed and large-document bench scripts (TD-09): the page and PDF generators are deterministic and valid, the peak-memory
parser reads both /usr/bin/time formats, the CSV rows carry the machine, the command and 'not measured on 8 GB'."""
import importlib.util
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1]

try:
    import pagetriage_py
except ImportError as e:  # binding not installed
    pagetriage_py = None
    SKIP_REASON = f"needs the pagetriage_py binding: {e}"
else:
    SKIP_REASON = ""


def load(name):
    spec = importlib.util.spec_from_file_location(name, BENCH / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PureTests(unittest.TestCase):
    def test_peak_rss_is_read_from_both_time_formats(self):
        large = load("large_doc_eval")
        bsd = "        0.01 real         0.00 user         0.00 sys\n   4259840  maximum resident set size\n"
        gnu = "\tMaximum resident set size (kbytes): 4160\n"
        self.assertEqual(large.parse_peak_rss(bsd, "Darwin"), 4259840)
        self.assertEqual(large.parse_peak_rss(gnu, "Linux"), 4160 * 1024)
        self.assertIsNone(large.parse_peak_rss("nothing here", "Darwin"))
        self.assertIsNone(large.parse_peak_rss(bsd, "Linux"))

    def test_the_synthetic_pdf_is_deterministic_and_has_its_pages(self):
        large = load("large_doc_eval")
        a, b = large.build_pdf(7), large.build_pdf(7)
        self.assertEqual(a, b)
        self.assertNotEqual(a, large.build_pdf(8))
        self.assertTrue(a.startswith(b"%PDF-1.7"))
        self.assertEqual(a.count(b" 0 obj\n"), 3 + 2 * 7)

    def test_the_synthetic_page_is_deterministic_and_text_like(self):
        speed = load("speed_eval")
        a = speed.make_page(200, 300, 100)
        self.assertEqual(a, speed.make_page(200, 300, 100))
        self.assertEqual(len(a), 200 * 300)
        dark = sum(1 for v in a if v < 100)
        self.assertTrue(0.01 < dark / len(a) < 0.35, dark / len(a))

    def test_rows_name_machine_command_and_the_8_gb_caveat(self):
        speed = load("speed_eval")
        rows = speed.rows([(("A4 100 dpi", 827, 1169, 100), [10.0, 12.0, 11.0])], "python -I bench/speed_eval.py")
        self.assertEqual(len(rows[0]), len(speed.HEADER))
        r = dict(zip(speed.HEADER, rows[0]))
        self.assertEqual(r["median_ms"], "11.0")
        self.assertEqual(r["worst_ms"], "12.0")
        self.assertEqual(r["eight_gb_laptop"], "not measured on 8 GB")
        self.assertTrue(r["machine"] and r["command"] and r["commit"])

    def test_p95_of_a_short_list_is_its_largest(self):
        speed = load("speed_eval")
        self.assertEqual(speed.p95([3.0, 1.0, 2.0]), 3.0)


@unittest.skipIf(pagetriage_py is None, SKIP_REASON)
class BindingTests(unittest.TestCase):
    def test_the_synthetic_pdf_reads_back_with_the_right_page_count_and_streams_are_ok(self):
        import json

        large = load("large_doc_eval")
        pdf = large.build_pdf(25)
        report = json.loads(pagetriage_py.analyse_pdf_structure(pdf))
        self.assertEqual(report["document"]["pages"], 25)
        streams = json.loads(pagetriage_py.account_pdf_streams(pdf))
        self.assertEqual(streams["verdict"], "ok")
        self.assertEqual(streams["streams"]["by_kind"]["content"]["count"], 25)

    def test_speed_measure_returns_one_time_per_run(self):
        speed = load("speed_eval")
        times = speed.measure(pagetriage_py, 200, 280, 100, 2)
        self.assertEqual(len(times), 2)
        self.assertTrue(all(t > 0 for t in times))


if __name__ == "__main__":
    unittest.main()
