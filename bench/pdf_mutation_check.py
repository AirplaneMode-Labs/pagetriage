#!/usr/bin/env python3
"""Mutated copies of the synthetic PDFs through the installed Python binding: 0 panics expected (Sprint 7, D2-04; the gate for a lopdf update).

    python -I bench/pdf_mutation_check.py [--per-file N] [--seed S]

Every PDF in tests/golden/pdf and tests/golden/streams_inputs is mutated N times (default 1000) by one of five operations (byte flips,
truncation, a deleted, a duplicated or a zeroed chunk), deterministically from the seed, and given to `analyse_pdf_structure` and to
`account_pdf_streams`. An answer is `ok`; a ValueError that the binding raises for input it will not analyse is `error`; the binding's own
panic guard ("the PDF parser panicked on this input") is `parser_panic`; anything else, a Python-level panic included, is `crash`. Exit 1
when there is a `parser_panic` or a `crash`. It also prints the slowest call. Synthetic inputs only; nothing is read from outside the repository.
Needs pagetriage_py (scripts/determinism.sh installs it into .venv with maturin develop).
"""
import argparse
import pathlib
import sys
import time

OPS = ("flip", "truncate", "delete", "duplicate", "zero")
ROOT = pathlib.Path(__file__).resolve().parents[1]


class Rng:
    """xorshift32: the same sequence on every platform and Python version."""

    def __init__(self, seed):
        self.s = (seed * 2654435761 + 1) & 0xFFFFFFFF or 1

    def next(self):
        s = self.s
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        self.s = s
        return s

    def below(self, n):
        return self.next() % n if n > 0 else 0


def mutate(data, rng):
    """(operation, mutated bytes). An empty input stays empty."""
    op = OPS[rng.below(len(OPS))]
    if not data:
        return op, data
    b = bytearray(data)
    if op == "flip":
        for _ in range(1 + rng.below(8)):
            b[rng.below(len(b))] = rng.next() & 0xFF
    elif op == "truncate":
        del b[1 + rng.below(len(b)):]
    else:
        start = rng.below(len(b))
        length = 1 + rng.below(min(512, len(b) - start))
        if op == "delete":
            del b[start:start + length]
        elif op == "duplicate":
            b[start:start] = b[start:start + length]
        else:
            b[start:start + length] = bytes(length)
    return op, bytes(b)


def classify(call, data):
    try:
        call(data)
    except ValueError as e:
        return "parser_panic" if "panicked" in str(e) else "error"
    except BaseException:  # a pyo3 PanicException derives from BaseException
        return "crash"
    return "ok"


def run(files, per_file, seed, call):
    """(counts, slowest seconds) over every file; `call` takes bytes."""
    counts = {"ok": 0, "error": 0, "parser_panic": 0, "crash": 0}
    slowest = 0.0
    for i, (name, data) in enumerate(sorted(files.items())):
        rng = Rng(seed + i)
        for _ in range(per_file):
            _op, m = mutate(data, rng)
            t0 = time.perf_counter()
            counts[classify(call, m)] += 1
            slowest = max(slowest, time.perf_counter() - t0)
    return counts, slowest


def exit_status(counts):
    return 1 if counts["parser_panic"] or counts["crash"] else 0


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-file", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=20261120)
    args = ap.parse_args(argv)
    import pagetriage_py as pt
    files = {}
    for d in ("tests/golden/pdf", "tests/golden/streams_inputs"):
        for p in sorted((ROOT / d).glob("*.pdf")):
            files[f"{d}/{p.name}"] = p.read_bytes()
    if not files:
        print("no synthetic PDFs found", file=sys.stderr)
        return 2
    total = {"ok": 0, "error": 0, "parser_panic": 0, "crash": 0}
    for label, call in (("analyse_pdf_structure", pt.analyse_pdf_structure), ("account_pdf_streams", pt.account_pdf_streams)):
        counts, slowest = run(files, args.per_file, args.seed, call)
        print(f"{label}: {sum(counts.values())} mutated copies of {len(files)} files: ok {counts['ok']}, error {counts['error']}, "
              f"parser_panic {counts['parser_panic']}, crash {counts['crash']}; slowest call {slowest * 1000:.0f} ms")
        for k in total:
            total[k] += counts[k]
    status = exit_status(total)
    print("mutation check:", "0 panics, 0 crashes" if status == 0 else "FAILED")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
