#!/usr/bin/env python3
"""How long does `analyse_page` take? (TD-09: the speed bench script deferred from Sprint 4.)

    python -I bench/speed_eval.py                       print the table
    python -I bench/speed_eval.py --csv docs/benchmarks/speed.csv --runs 5

Synthetic gray pages of A4 at 100, 150, 200 and 300 dpi (text-like lines on paper, a seeded integer generator, so the
same bytes on every machine) go through the Python binding with the default detectors. Per size it reports the pixel
count, the median and the worst of N runs in milliseconds, and megapixels per second at the median. No algorithm lives
here: it builds a page, calls the core and reads a clock. The core itself never reads the clock (CLAUDE.md); the clock is
this harness's.

Needs `pagetriage_py` (maturin develop --release -m crates/pagetriage-py/Cargo.toml). The figures are for the machine
named in every row; none is an 8 GB laptop figure (not measured on 8 GB).
"""
import argparse
import csv
import datetime
import platform
import statistics
import subprocess
import sys
import time

# (label, width, height): A4 at the stated resolution
SIZES = [("A4 100 dpi", 827, 1169, 100), ("A4 150 dpi", 1240, 1754, 150), ("A4 200 dpi", 1654, 2339, 200), ("A4 300 dpi", 2480, 3508, 300)]
HEADER = ["date", "machine", "command", "commit", "page", "width", "height", "dpi", "megapixels", "runs", "median_ms", "worst_ms", "megapixels_per_second", "eight_gb_laptop"]
EIGHT_GB = "not measured on 8 GB"


class Lcg:
    """32-bit linear congruential generator (Numerical Recipes constants), as tests/golden/gen_inputs.py uses."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, bound):
        self.state = (self.state * 1664525 + 1013904223) & 0xFFFFFFFF
        return (self.state >> 16) % bound


def make_page(width, height, dpi, seed=7):
    """A gray page: paper at 245, text-like lines (runs of dark pixels 2 to 14 px apart) every 0.17 inch."""
    page = bytearray([245]) * (width * height)
    rng = Lcg(seed)
    line_height = max(6, round(dpi * 0.17))
    ink = max(2, round(dpi * 0.03))
    margin = round(dpi * 0.8)
    for top in range(margin, height - margin, line_height):
        x = margin
        while x < width - margin:
            run = 2 + rng.next(dpi // 12 + 3)
            gap = 2 + rng.next(dpi // 25 + 2)
            end = min(x + run, width - margin)
            for y in range(top, min(top + ink, height)):
                base = y * width
                page[base + x : base + end] = bytes([30]) * (end - x)
            x = end + gap
    return bytes(page)


def p95(values):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))]


def measure(pagetriage_py, width, height, dpi, runs):
    page = make_page(width, height, dpi)
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        pagetriage_py.analyse_page(page, width, height, dpi)
        times.append((time.perf_counter() - t) * 1000.0)
    return times


def machine():
    brand = ""
    try:
        brand = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    except OSError:
        pass
    return f"{brand or platform.processor() or platform.machine()} ({platform.system()} {platform.release()} {platform.machine()})"


def commit():
    try:
        c = subprocess.run(["git", "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip()
        return c + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def today():
    """UTC date of the run, YYYY-MM-DD."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def rows(results, command):
    out = []
    d, m, c = today(), machine(), commit()
    for (label, w, h, dpi), times in results:
        med = statistics.median(times)
        mp = w * h / 1e6
        out.append([d, m, command, c, label, w, h, dpi, f"{mp:.2f}", len(times), f"{med:.1f}", f"{max(times):.1f}", f"{mp / (med / 1000.0):.2f}", EIGHT_GB])
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--csv", help="write the rows here")
    ap.add_argument("--sizes", help="comma separated dpi values to run (default: all)")
    args = ap.parse_args(argv)
    try:
        import pagetriage_py
    except ImportError as e:
        print(f"needs the pagetriage_py binding: {e}", file=sys.stderr)
        return 2
    sizes = SIZES if not args.sizes else [s for s in SIZES if str(s[3]) in args.sizes.split(",")]
    results = [(s, measure(pagetriage_py, s[1], s[2], s[3], args.runs)) for s in sizes]
    command = f"python -I bench/speed_eval.py --runs {args.runs}" + (f" --csv {args.csv}" if args.csv else "")
    table = rows(results, command)
    shown = ["page", "width", "height", "megapixels", "runs", "median_ms", "worst_ms", "megapixels_per_second"]
    print(",".join(shown))
    for r in table:
        row = dict(zip(HEADER, r))
        print(",".join(str(row[k]) for k in shown))
    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f, lineterminator="\n")
            w.writerow(HEADER)
            w.writerows(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
