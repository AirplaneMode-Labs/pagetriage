#!/usr/bin/env python3
"""Keep the raw output of one bench command, with the date, commit, machine and command that made it.

    python -I bench/record.py --out docs/benchmarks/eval-qr.json -- python -I bench/qr_synth_eval.py
    python -I bench/record.py --check docs/benchmarks/eval-qr.json     # is the file well formed?

The wrapped command runs from the repository root. Its standard output and error are stored line by line in one JSON
file under `docs/benchmarks/`, next to the provenance a reader needs to judge a figure: the UTC date, the git commit
(`-dirty` when the tree had uncommitted changes), the machine (model and RAM only, no host or user name), the exact
command, its exit code and its wall time. Nothing is edited: the lines are what the command printed, except that the
absolute path of the repository and of the home folder are replaced by `<repo>` and `~` so that no builder path is
committed. The 8 GB field says "not measured on 8 GB" unless the run is given `--eight-gb "measured on 8 GB: <the machine>"`, the only way a record can say that it was
made on an 8 GB laptop; tests/scripts/benchmarks-check.mjs then requires an 8 GB machine in it.

No algorithm lives here. It runs a command and writes down what happened.
"""
import argparse
import datetime
import json
import os
import platform
import subprocess
import sys
import time

SCHEMA = "pagetriage-bench-record-1"
EIGHT_GB = "not measured on 8 GB"
MEASURED_PREFIX = "measured on 8 GB:"
REQUIRED = ["schema", "name", "date", "commit", "machine", "command", "exit_code", "wall_seconds", "eight_gb_laptop", "stdout", "stderr"]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _sysctl(name):
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def machine():
    """Model and RAM only: 'Apple M5 Pro (Mac17,8), 48 GiB RAM, Darwin arm64'. No host name, user name or serial."""
    system, arch = platform.system(), platform.machine()
    if system == "Darwin":
        brand, model, mem = _sysctl("machdep.cpu.brand_string"), _sysctl("hw.model"), _sysctl("hw.memsize")
        ram = f"{round(int(mem) / 2**30)} GiB RAM" if mem.isdigit() else "RAM unknown"
        return f"{brand or 'Apple silicon'}{f' ({model})' if model else ''}, {ram}, {system} {arch}"
    cpu, ram = platform.processor() or arch, "RAM unknown"
    try:
        if system == "Linux":
            with open("/proc/cpuinfo", encoding="utf-8") as f:
                cpu = next((l.split(":", 1)[1].strip() for l in f if l.startswith("model name")), cpu)
            with open("/proc/meminfo", encoding="utf-8") as f:
                kib = next(int(l.split()[1]) for l in f if l.startswith("MemTotal"))
            ram = f"{round(kib / 2**20)} GiB RAM"
    except (OSError, StopIteration, ValueError):
        pass
    return f"{cpu}, {ram}, {system} {arch}"


def commit():
    try:
        c = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True, check=True).stdout.strip()
        return c + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def tools():
    """Versions of the Python and the packages the bench scripts use, as this interpreter sees them (run the recorder from the
    same environment as the command)."""
    from importlib import metadata

    found = {"python": platform.python_version()}
    for pkg in ("numpy", "Pillow", "qrcode", "augraphy", "pagetriage"):
        try:
            found[pkg] = metadata.version(pkg)
        except metadata.PackageNotFoundError:
            pass
    return found


def scrub(text):
    """Replace the repository's absolute path and the home folder, longest first, so no builder path is committed."""
    for needle, repl in sorted([(ROOT, "<repo>"), (os.path.expanduser("~"), "~")], key=lambda p: -len(p[0])):
        if needle and needle != "/":
            text = text.replace(needle, repl)
    return text


def record(name, command, out, eight_gb=EIGHT_GB):
    started = datetime.datetime.now(datetime.timezone.utc)
    t = time.perf_counter()
    proc = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    wall = time.perf_counter() - t
    doc = {
        "schema": SCHEMA,
        "name": name,
        "date": started.strftime("%Y-%m-%d"),
        "started_utc": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": commit(),
        "machine": machine(),
        "tools": tools(),
        "command": scrub(" ".join(command)),
        "exit_code": proc.returncode,
        "wall_seconds": round(wall, 1),
        "eight_gb_laptop": eight_gb,
        "stdout": scrub(proc.stdout).splitlines(),
        "stderr": scrub(proc.stderr).splitlines(),
    }
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    return doc


def problems(doc):
    """What is wrong with a parsed record (an empty list when it is complete)."""
    bad = [f"missing {k}" for k in REQUIRED if k not in doc]
    if doc.get("schema") != SCHEMA:
        bad.append(f"schema is not {SCHEMA}")
    for k in ("name", "date", "commit", "machine", "command"):
        if k in doc and not str(doc[k]).strip():
            bad.append(f"{k} is empty")
    if "date" in doc and not (len(str(doc["date"])) == 10 and str(doc["date"])[4] == "-" and str(doc["date"])[7] == "-"):
        bad.append("date is not YYYY-MM-DD")
    claim = doc.get("eight_gb_laptop")
    if claim != EIGHT_GB and not (isinstance(claim, str) and claim.startswith(MEASURED_PREFIX) and len(claim) > len(MEASURED_PREFIX) + 8):
        bad.append(f"eight_gb_laptop is neither '{EIGHT_GB}' nor '{MEASURED_PREFIX} <the machine>'")
    if doc.get("exit_code") != 0:
        bad.append(f"exit_code is {doc.get('exit_code')}")
    if not doc.get("stdout"):
        bad.append("stdout is empty")
    return bad


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", help="the JSON file to write")
    ap.add_argument("--name", help="short name of the run (default: the file name without eval- and .json)")
    ap.add_argument("--eight-gb", metavar="TEXT", help=f'"{MEASURED_PREFIX} <Windows version, CPU, RAM, GPU, Chrome>": says the run was made on an 8 GB laptop (default: "{EIGHT_GB}")')
    ap.add_argument("--check", metavar="FILE", help="verify an existing record and exit")
    if "--" in argv:
        i = argv.index("--")
        args, command = ap.parse_args(argv[:i]), argv[i + 1 :]
    else:
        args, command = ap.parse_args(argv), []
    if args.check:
        with open(args.check, encoding="utf-8") as f:
            bad = problems(json.load(f))
        for b in bad:
            print(f"{args.check}: {b}", file=sys.stderr)
        return 1 if bad else 0
    if not args.out or not command:
        ap.error("give --out FILE and, after --, the command to run")
    name = args.name or os.path.basename(args.out).removeprefix("eval-").removesuffix(".json")
    if args.eight_gb is not None and not args.eight_gb.startswith(MEASURED_PREFIX):
        ap.error(f'--eight-gb must start with "{MEASURED_PREFIX}"')
    doc = record(name, command, args.out, args.eight_gb or EIGHT_GB)
    print(f"{args.out}: exit {doc['exit_code']}, {len(doc['stdout'])} lines, {doc['wall_seconds']} s")
    return 0 if doc["exit_code"] == 0 else doc["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
