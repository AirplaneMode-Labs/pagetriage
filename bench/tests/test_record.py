"""bench/record.py keeps a bench command's raw output with its provenance: date, commit, machine, command, exit code.
These tests run it on a command that prints fixed lines and check what lands in the JSON file, that no builder path
survives, that the machine label carries a model and a RAM figure and no host or user name, and that a record missing
a provenance field is refused."""
import importlib.util
import json
import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("record", BENCH / "record.py")
record = importlib.util.module_from_spec(spec)
spec.loader.exec_module(record)


class RecordTests(unittest.TestCase):
    def run_record(self, code):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "eval-fixture.json")
            doc = record.record("fixture", [sys.executable, "-I", "-c", code], out)
            with open(out, encoding="utf-8") as f:
                self.assertEqual(json.load(f), doc)
            return doc

    def test_the_output_is_kept_line_for_line_with_its_provenance(self):
        doc = self.run_record("print('a  1.00'); print('b  2.50'); import sys; print('warn', file=sys.stderr)")
        self.assertEqual(doc["stdout"], ["a  1.00", "b  2.50"])
        self.assertEqual(doc["stderr"], ["warn"])
        self.assertEqual(doc["exit_code"], 0)
        self.assertEqual(record.problems(doc), [])
        for key in ("date", "commit", "machine", "command"):
            self.assertTrue(doc[key], key)
        self.assertRegex(doc["date"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertEqual(doc["eight_gb_laptop"], "not measured on 8 GB")

    def test_a_failing_command_is_recorded_and_refused(self):
        doc = self.run_record("import sys; print('partial'); sys.exit(3)")
        self.assertEqual(doc["exit_code"], 3)
        self.assertIn("exit_code is 3", record.problems(doc))

    def test_no_builder_path_survives(self):
        doc = self.run_record(f"print({str(record.ROOT)!r} + '/bench/x.py'); print({os.path.expanduser('~')!r} + '/secret')")
        self.assertEqual(doc["stdout"][0], "<repo>/bench/x.py")
        self.assertTrue(doc["stdout"][1].startswith("~") or doc["stdout"][1].startswith("<repo>"), doc["stdout"][1])
        self.assertNotIn(os.path.expanduser("~"), json.dumps(doc))

    def test_the_machine_label_is_model_and_ram_only(self):
        label = record.machine()
        self.assertRegex(label, r"RAM")
        self.assertNotIn(socket.gethostname(), label)
        self.assertNotIn(os.environ.get("USER", "\0"), label)

    def test_a_record_missing_provenance_is_refused(self):
        doc = self.run_record("print('x')")
        for key in ("date", "commit", "machine", "command"):
            broken = dict(doc)
            broken[key] = ""
            self.assertTrue(any(key in p for p in record.problems(broken)), key)
        broken = dict(doc)
        broken.pop("date")
        self.assertIn("missing date", record.problems(broken))
        self.assertIn("date is not YYYY-MM-DD", record.problems({**doc, "date": "yesterday"}))
        self.assertTrue(any("8 GB" in p for p in record.problems({**doc, "eight_gb_laptop": "8 GB laptop: 40 ms"})))
        self.assertEqual(record.problems({**doc, "eight_gb_laptop": "measured on 8 GB: Windows 11, i5, 8 GB, no GPU, Chrome 150"}), [])
        self.assertTrue(record.problems({**doc, "eight_gb_laptop": "measured on 8 GB:"}))
        self.assertIn("stdout is empty", record.problems({**doc, "stdout": []}))


if __name__ == "__main__":
    unittest.main()
