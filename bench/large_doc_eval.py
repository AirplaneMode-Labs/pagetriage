#!/usr/bin/env python3
"""Large synthetic PDFs through the release CLI: time and peak memory of `structure` and `streams`
(TD-09: the large-document bench script deferred from Sprint 4).

    cargo build --release -p pagetriage-cli
    python -I bench/large_doc_eval.py --pages 100,1000,5000 --csv docs/benchmarks/large-doc.csv

Each document is a text-only PDF of N pages (52 lines of seeded common words per page, no real text), written by this
script with a classic cross-reference table, so the bytes are the same on every machine. The CLI runs under
`/usr/bin/time` (BSD `-l` on macOS, GNU `-v` on Linux), which is where the peak resident memory comes from; the wall time
is measured around the process. No algorithm lives here. The figures are for the machine named in every row; none is an
8 GB laptop figure (not measured on 8 GB).
"""
import argparse
import csv
import os
import platform
import re
import subprocess
import sys
import tempfile
import time

HEADER = ["machine", "command", "commit", "pages", "file_bytes", "call", "exit_code", "wall_ms", "peak_rss_bytes", "eight_gb_laptop"]
EIGHT_GB = "not measured on 8 GB"
WORDS = "the of and to in is that for it as was with be by on not he this are or his from at which but have an had they you were their one all we can her has there been if more when will would who so no".split()


class Lcg:
    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, bound):
        self.state = (self.state * 1664525 + 1013904223) & 0xFFFFFFFF
        return (self.state >> 16) % bound


def build_pdf(pages, lines=52, seed=3):
    """A classic-xref PDF of `pages` pages of seeded text. Objects: 1 catalog, 2 pages, 3 font, then 4 + 2k page and 5 + 2k content."""
    rng = Lcg(seed)
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}

    def obj(num, body):
        offsets[num] = len(out)
        out.extend(b"%d 0 obj\n" % num + body + b"\nendobj\n")

    kids = " ".join(f"{4 + 2 * k} 0 R" for k in range(pages))
    obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    obj(2, f"<< /Type /Pages /Kids [{kids}] /Count {pages} >>".encode())
    obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    for k in range(pages):
        text = ["BT /F1 10 Tf 36 800 Td 14 TL"]
        for _ in range(lines):
            text.append("(" + " ".join(WORDS[rng.next(len(WORDS))] for _ in range(11)) + ") '")
        text.append("ET")
        data = "\n".join(text).encode("latin-1")
        obj(4 + 2 * k, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents {5 + 2 * k} 0 R /Resources << /Font << /F1 3 0 R >> >> >>".encode())
        obj(5 + 2 * k, b"<< /Length %d >>\nstream\n" % len(data) + data + b"\nendstream")
    size = 4 + 2 * pages
    at = len(out)
    xref = [b"xref\n0 %d\n" % size, b"0000000000 65535 f \n"]
    xref += [b"%010d 00000 n \n" % offsets[n] for n in range(1, size)]
    out.extend(b"".join(xref))
    out.extend(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (size, at))
    return bytes(out)


def parse_peak_rss(time_stderr, system):
    """Peak resident bytes from `/usr/bin/time` output: BSD `-l` prints bytes, GNU `-v` prints KiB."""
    if system == "Darwin":
        m = re.search(r"^\s*(\d+)\s+maximum resident set size", time_stderr, re.M)
        return int(m.group(1)) if m else None
    m = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", time_stderr)
    return int(m.group(1)) * 1024 if m else None


def run_timed(cli, call, path):
    system = platform.system()
    flag = "-l" if system == "Darwin" else "-v"
    t = time.perf_counter()
    p = subprocess.run(["/usr/bin/time", flag, cli, call, path], capture_output=True, text=True)
    wall = (time.perf_counter() - t) * 1000.0
    return p.returncode, wall, parse_peak_rss(p.stderr, system)


def commit():
    try:
        c = subprocess.run(["git", "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip()
        return c + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def machine():
    brand = ""
    try:
        brand = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    except OSError:
        pass
    return f"{brand or platform.processor() or platform.machine()} ({platform.system()} {platform.release()} {platform.machine()}, {os.cpu_count()} cores)"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pages", default="100,1000,5000", help="comma separated page counts")
    ap.add_argument("--cli", default=os.path.join(os.environ.get("CARGO_TARGET_DIR", "target"), "release", "pagetriage"))
    ap.add_argument("--csv", help="write the rows here")
    args = ap.parse_args(argv)
    if not os.path.exists(args.cli):
        print(f"{args.cli} not built: cargo build --release -p pagetriage-cli", file=sys.stderr)
        return 2
    command = f"python -I bench/large_doc_eval.py --pages {args.pages}" + (f" --csv {args.csv}" if args.csv else "")
    rows = []
    m, c = machine(), commit()
    with tempfile.TemporaryDirectory(prefix="pagetriage-largedoc-") as tmp:
        for n in (int(x) for x in args.pages.split(",")):
            path = os.path.join(tmp, f"synthetic-{n}p.pdf")
            data = build_pdf(n)
            with open(path, "wb") as f:
                f.write(data)
            for call in ("structure", "streams"):
                code, wall, peak = run_timed(args.cli, call, path)
                rows.append([m, command, c, n, len(data), call, code, f"{wall:.0f}", peak if peak is not None else "", EIGHT_GB])
                print(f"{n:>6} pages {len(data):>10} bytes  {call:<9} exit {code}  {wall:>8.0f} ms  peak {peak if peak is not None else '?'} bytes")
    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f, lineterminator="\n")
            w.writerow(HEADER)
            w.writerows(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
