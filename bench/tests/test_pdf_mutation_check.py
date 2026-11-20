"""Offline checks on bench/pdf_mutation_check.py (Sprint 7, D2-04): the mutations are deterministic, the classification never mistakes a
parser panic for an ordinary refusal, and the exit status is non-zero when a panic or a crash is seen. A stand-in analyser replaces the binding."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pdf_mutation_check as pm  # noqa: E402

SAMPLE = b"%PDF-1.4\n" + bytes(range(256)) * 4 + b"\n%%EOF\n"


class Mutations(unittest.TestCase):
    def test_same_seed_same_mutants(self):
        a = [pm.mutate(SAMPLE, pm.Rng(7)) for _ in range(50)]
        b = [pm.mutate(SAMPLE, pm.Rng(7)) for _ in range(50)]
        self.assertEqual(a, b)

    def test_mutants_differ_from_the_original_and_each_other(self):
        rng = pm.Rng(1)
        mutants = {pm.mutate(SAMPLE, rng)[1] for _ in range(200)}
        self.assertGreater(len(mutants), 100)
        self.assertNotIn(SAMPLE, mutants - {SAMPLE} and set())

    def test_every_operation_is_used(self):
        rng = pm.Rng(3)
        ops = {pm.mutate(SAMPLE, rng)[0] for _ in range(400)}
        self.assertEqual(ops, set(pm.OPS))

    def test_an_empty_file_does_not_crash_the_mutator(self):
        self.assertEqual(pm.mutate(b"", pm.Rng(1))[1], b"")


class Classification(unittest.TestCase):
    def test_outcomes(self):
        self.assertEqual(pm.classify(lambda b: "{}", b"x"), "ok")
        def refuse(_b): raise ValueError("invalid input: cannot read PDF: failed parsing cross reference table")
        self.assertEqual(pm.classify(refuse, b"x"), "error")
        def panic(_b): raise ValueError("invalid input: cannot read PDF: the PDF parser panicked on this input")
        self.assertEqual(pm.classify(panic, b"x"), "parser_panic")
        def crash(_b): raise RuntimeError("boom")
        self.assertEqual(pm.classify(crash, b"x"), "crash")
        def pyo3(_b): raise BaseException("PanicException: assertion failed")
        self.assertEqual(pm.classify(pyo3, b"x"), "crash")

    def test_run_counts_and_exit_status(self):
        calls = []
        def analyser(b):
            calls.append(b)
            return "{}"
        counts, slowest = pm.run({"a.pdf": SAMPLE}, 25, 5, analyser)
        self.assertEqual(sum(counts.values()), 25)
        self.assertEqual(counts["parser_panic"] + counts["crash"], 0)
        self.assertEqual(pm.exit_status(counts), 0)
        self.assertGreaterEqual(slowest, 0.0)
        def panicky(_b): raise ValueError("the PDF parser panicked on this input")
        counts, _ = pm.run({"a.pdf": SAMPLE}, 10, 5, panicky)
        self.assertEqual(counts["parser_panic"], 10)
        self.assertEqual(pm.exit_status(counts), 1)


if __name__ == "__main__":
    unittest.main()
