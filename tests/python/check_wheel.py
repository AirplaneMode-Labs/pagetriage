#!/usr/bin/env python3
"""Static checks on a built pagetriage wheel (TD-09, the wheels job). Run with -I:

    python3 -I tests/python/check_wheel.py <wheel> <version>

Fails (exit 1) unless the wheel is a cp39-abi3 wheel of the given version that carries the compiled extension
(`pagetriage_py`), both licence files and a NOTICE with the MIT text; has no file over 5 MB, no wheel over 5 MB, no
scripts or entry points, no test data, no model files and no source maps; and whose WHEEL file lists exactly the tags the
filename names (PEP 425 compressed tag sets expanded, then compared as sets: see expand_tags). Prints one line per check.

The tests for the checks are tests/python/test_check_wheel.py. It says nothing about builder paths in the file contents
(scripts/check-no-builder-paths.sh does that) and nothing about what the wheel does when imported (the CI job installs it
into a fresh venv with --no-index and calls it).
"""
import os
import re
import sys
import zipfile

MAX_FILE = 5 * 1024 * 1024
# One alternative of one part of a tag (PEP 425): letters, digits and underscores, never empty, no dot.
TAG_ALT = re.compile(r"[A-Za-z0-9_]+")


def expand_tags(compressed: str) -> frozenset:
    """Expand a PEP 425 compressed tag set into the set of python-abi-platform triples it stands for.

    A wheel filename carries `<python>-<abi>-<platform>` where each part may hold several dot-separated alternatives,
    and the tag set is the cross product of the three parts: the manylinux wheel CI builds is named
    `...-cp39-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl` and stands for two tags. Raises ValueError for anything
    that is not three non-empty dash-separated parts of [A-Za-z0-9_] alternatives.
    """
    parts = compressed.split("-")
    if len(parts) != 3:
        raise ValueError(f"{compressed!r} is not <python>-<abi>-<platform> (want 3 dash-separated parts, got {len(parts)})")
    alts = []
    for part in parts:
        a = part.split(".")
        if not all(TAG_ALT.fullmatch(x) for x in a):
            raise ValueError(f"{part!r} in {compressed!r} is not a dot-separated list of non-empty [A-Za-z0-9_] tags")
        alts.append(a)
    return frozenset(f"{py}-{abi}-{plat}" for py in alts[0] for abi in alts[1] for plat in alts[2])


def wheel_file_tags(wheel_meta: str) -> frozenset:
    """The expanded tag set a WHEEL file records: every header named exactly `Tag` (maturin writes one per expanded tag),
    expanded like a filename tag. Other headers, and text that merely contains `Tag:`, are not tags."""
    tags = set()
    for line in re.split(r"\r?\n", wheel_meta):
        key, sep, value = line.partition(":")
        if sep and key == "Tag":
            tags |= expand_tags(value.strip())
    return frozenset(tags)


def tag_mismatch(filename_tags: str, wheel_meta: str):
    """None when the WHEEL file records exactly the tags the filename names (compared as expanded sets, so the order of the
    Tag lines and of the dot-separated alternatives does not matter and nothing may be missing or extra); otherwise a one-line
    description of the difference, or of what could not be parsed."""
    try:
        want = expand_tags(filename_tags)
        have = wheel_file_tags(wheel_meta)
    except ValueError as e:
        return str(e)
    if want == have:
        return None
    said = []
    if want - have:
        said.append("in the filename but not in WHEEL: " + ", ".join(sorted(want - have)))
    if have - want:
        said.append("in WHEEL but not in the filename: " + ", ".join(sorted(have - want)))
    return "; ".join(said)


def main(argv: list) -> int:
    if len(argv) != 3:
        print("usage: check_wheel.py <wheel> <version>", file=sys.stderr)
        return 2
    wheel, version = argv[1], argv[2]
    failures = 0

    def check(ok: bool, what: str) -> None:
        nonlocal failures
        print(("ok   " if ok else "FAIL ") + what)
        if not ok:
            failures += 1

    name = os.path.basename(wheel)
    m = re.fullmatch(r"pagetriage-(?P<v>[^-]+)-cp39-abi3-(?P<plat>[A-Za-z0-9_.]+)\.whl", name)
    check(m is not None and m.group("v") == version, f"wheel name is pagetriage-{version}-cp39-abi3-<platform>.whl (got {name})")
    plat = m.group("plat") if m else "?"
    print(f"     platform tag: {plat}")

    with zipfile.ZipFile(wheel) as z:
        infos = z.infolist()
        names = [i.filename for i in infos]
        di = f"pagetriage-{version}.dist-info/"
        check(any(n.startswith("pagetriage_py/") and (n.endswith(".abi3.so") or n.endswith(".pyd")) for n in names), "the compiled extension (pagetriage_py) is in the wheel")
        check(di + "licenses/LICENSE-MIT" in names, "LICENSE-MIT is in the wheel")
        check(di + "licenses/LICENSE-APACHE" in names, "LICENSE-APACHE is in the wheel")
        check(di + "licenses/NOTICE" in names, "NOTICE is in the wheel")
        if di + "licenses/NOTICE" in names:
            nt = z.read(di + "licenses/NOTICE").decode("utf-8")
            check("Permission is hereby granted" in nt and "THE SOFTWARE IS PROVIDED" in nt, "the wheel NOTICE carries the MIT text")
        big = [(i.filename, i.file_size) for i in infos if i.file_size > MAX_FILE]
        check(not big, f"no file over 5 MB {big if big else ''}")
        size = os.path.getsize(wheel)
        check(size < MAX_FILE, f"the wheel is under 5 MB ({size} bytes)")
        bad = [n for n in names if re.search(r"(\.map$|\.onnx$|\.safetensors$|\.gguf$|(^|/)tests?/|\.data/scripts/|entry_points\.txt$|\.pth$)", n)]
        check(not bad, f"no source maps, model files, tests, scripts or entry points {bad if bad else ''}")
        unexpected = [n for n in names if not (n.startswith("pagetriage_py/") or n.startswith(di))]
        check(not unexpected, f"every file is under pagetriage_py/ or the dist-info {unexpected if unexpected else ''}")
        wheel_meta = z.read(di + "WHEEL").decode("utf-8") if di + "WHEEL" in names else ""

    # PEP 425/427: the filename carries a compressed tag set and WHEEL one Tag line per expanded tag, so the two are compared
    # as expanded sets (the CI lesson of 18 Nov 2026: a plain string compare failed the manylinux wheel only).
    mismatch = tag_mismatch(f"cp39-abi3-{plat}", wheel_meta) if m else "the filename did not parse, so its tags are unknown"
    check(mismatch is None, "WHEEL records the same tag set as the filename (compressed tags expanded, compared as sets)")
    if mismatch is not None:
        print(f"     {mismatch}")
    else:
        print(f"     tags: {', '.join(sorted(wheel_file_tags(wheel_meta)))}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
