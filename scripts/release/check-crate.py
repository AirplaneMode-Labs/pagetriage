#!/usr/bin/env python3
"""Check that a packaged .crate holds LICENSE-APACHE, LICENSE-MIT and NOTICE, each non-empty, next to Cargo.toml in <name>-<version>/.

    python3 -I scripts/release/check-crate.py <file.crate> <name-version>

The packaged crates are part of the signed set, and the charter requires the licence texts and a NOTICE inside every packed tarball, wheel,
sdist and crate (BUG-T3-S7-04: pagetriage-core once shipped without a NOTICE). scripts/release/rehearse.sh's gate runs this on every .crate in
dist-release/. Exit 0 and one `ok` line when all three are there; exit 1 and the names that are missing (or `unreadable`) otherwise; exit 2 on a
usage error. Reads the archive with the standard library only, never extracts it, and uses no path from inside it.
"""
import sys
import tarfile

NEED = ("LICENSE-APACHE", "LICENSE-MIT", "NOTICE")


def main(argv):
    if len(argv) != 3:
        print("usage: check-crate.py <file.crate> <name-version>", file=sys.stderr)
        return 2
    path, stem = argv[1], argv[2]
    try:
        with tarfile.open(path, "r:gz") as t:
            sizes = {m.name: m.size for m in t.getmembers() if m.isfile()}
    except (tarfile.TarError, OSError, EOFError) as e:
        print(f"unreadable ({type(e).__name__})")
        return 1
    missing = [n for n in NEED if sizes.get(f"{stem}/{n}", 0) <= 0]
    if missing:
        print("missing or empty: " + ", ".join(missing))
        return 1
    print(f"ok: {stem} holds {', '.join(NEED)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
