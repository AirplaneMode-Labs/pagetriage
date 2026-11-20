#!/usr/bin/env python3
"""Print the size of each WebAssembly build and each release artefact, one line each, for bench/record.py to keep.

    python -I bench/sizes_report.py --wasm pixel-only=dist/wasm-pixel/web/pagetriage_bg.wasm --wasm pdf=dist/wasm-pdf/web/pagetriage_bg.wasm --dir dist-release

A WebAssembly file is measured raw and with `gzip -9` of the gzip command-line tool, the figure scripts/check-wasm-size.sh checks against its
budget (Python's zlib and node's zlib give other, larger counts, so they are not used). A file in --dir is measured as it is, with its SHA-256.
Nothing is computed from the sizes and nothing is judged: the lines are what `wc -c` and `gzip -9 -c | wc -c` would print. The artefacts embed
README.md (every one of them carries it), so their byte counts change with any edit of the README; a row says which commit and date they were built at.
"""
import argparse
import hashlib
import os
import subprocess
import sys


def gzip9(path):
    """Bytes of `gzip -9 -c path` (the CLI, as scripts/check-wasm-size.sh does it)."""
    return len(subprocess.run(["gzip", "-9", "-c", path], capture_output=True, check=True).stdout)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wasm", action="append", default=[], metavar="LABEL=PATH", help="a WebAssembly file, measured raw and gzip -9")
    ap.add_argument("--dir", help="a folder of release artefacts (npm tarball, wheel, sdist, crates); manifests and checksum files are skipped")
    args = ap.parse_args(argv)
    print("artefact,measure,bytes,sha256")
    for spec in args.wasm:
        label, _, path = spec.partition("=")
        if not path or not os.path.isfile(path):
            print(f"not a file: {spec}", file=sys.stderr)
            return 2
        print(f"wasm {label},raw,{os.path.getsize(path)},{sha256(path)}")
        print(f"wasm {label},gzip -9,{gzip9(path)},")
    if args.dir:
        for name in sorted(os.listdir(args.dir)):
            path = os.path.join(args.dir, name)
            if not os.path.isfile(path) or name in ("SHA256SUMS", "release-manifest.json"):
                continue
            print(f"{name},file,{os.path.getsize(path)},{sha256(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
