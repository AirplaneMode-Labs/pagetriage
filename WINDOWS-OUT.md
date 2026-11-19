# `--out` on Windows: what `release-manifest.mjs` accepts and why

Status: Sprint 6 (19 Nov 2026). **Working:** `scripts/lib/confine.mjs` (the `--out` containment of `scripts/release-manifest.mjs`)
refuses the reserved device names `COM0` to `COM9`, `LPT0` to `LPT9` and their superscript forms, and compares the directory
prefix case-exactly after `realpath.native`. Both are tested on `path.win32` with an in-memory volume, on macOS.
**Not yet:** no real Windows file system has run these two changes. The CI job `fmt, clippy, test (windows-latest)` runs the same
tests on a real runner after the owner's push, and no runner has created a case-sensitive NTFS directory (that needs
`fsutil file setCaseSensitiveInfo`, which needs WSL), so S1-106 stays "proven on a model". Nothing is tagged or published.

The rest of the rules (extended-length and UNC prefixes, drive-relative paths, `:` streams, trailing dots and spaces, forbidden
characters, links and junctions, the `wx` temporary file and rename) are described in the header of `scripts/lib/confine.mjs` and
in `docs/release.md`, "Output confinement"; they did not change.

## T2-NOTE-COM0: `COM0` and `LPT0`

The reserved-name rule listed `COM1` to `COM9` and `LPT1` to `LPT9`. Current Windows also treats `COM0` and `LPT0` as devices, so
`dist\COM0` was accepted by the rule and refused (or worse) by the file system. The rule is now
`/^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³]|conin\$|conout\$)$/i`, applied to the text before the first dot of a component with
trailing spaces removed, so `COM0`, `com0.json`, `Lpt0.tar.gz` and `dist\sub\COM0.log` are refused and `com00`, `lpt10`, `xcom0` and
`com` are not. Superscript digits are U+00B9, U+00B2 and U+00B3; `COM⁴` is not a device name and is accepted.

## S1-106: case sensitivity per directory

**The problem.** After `realpath.native` has given `dist/` and the deepest existing ancestor of `--out` their on-disk spelling, the
containment test was `path.win32.relative(distReal, final)`, which compares case-insensitively. On an NTFS directory with
per-directory case sensitivity switched on (`fsutil file setCaseSensitiveInfo <dir> enable`, which WSL does), `DIST` can sit next to
`dist` as another directory, and `relative('C:\repo\dist', 'C:\repo\DIST\x')` is `x`: a write into the wrong directory would have
been accepted.

**The decision: fix it, do not keep the documented refusal.** Both sides are canonical by the time they are compared, so a
difference in case is a difference in directory. Containment is now two tests, both of which must pass:

1. `rel = relative(distReal, final)`, with the old rules (non-empty, not absolute, not `..` or `..` plus a separator);
2. `final.startsWith(distReal + sep)`, compared exactly.

Why this does not refuse what it should accept: on a normal case-insensitive volume every spelling of `dist` (`DIST`, `Dist`, a
drive letter in lower case, an 8.3 short name) is resolved by `realpath.native` to the one on-disk name before the comparison, so
the exact test sees `dist` and passes. Where the directory does not exist yet the remainder of the path is below an existing
ancestor that has already been canonicalised, and `dist/` itself is created first, so it always exists. The tests below show both
sides: the case-insensitive model still accepts `DIST\x.json`, `Dist\sub\x.json` and a lower-case repository path, and the
case-sensitive model refuses `DIST\x.json`, `Dist\x.json`, `dIsT\sub\x.json` and a sibling `Dist.d`.

**What proves it, and what does not.** `tests/scripts/confine.test.mjs` (run by `tests/scripts/run-all.sh`) has a `FakeFs` volume
with `path.win32` and exact name lookup (`winCaseSensitiveVolume`, `dist` and `DIST` both present) and the existing
case-insensitive Windows volume. No test depends on the case sensitivity of the machine it runs on: the volumes are in memory, the
cases feed case-different spellings explicitly, and the real-file-system tests use names without case differences. The red run
(`confine.test.mjs` against the Sprint 5 `confine.mjs`) fails the COM0 test and the case-sensitive test; the green run is 41
pass, 0 fail, 0 skipped. A real case-sensitive NTFS directory has not been tried: the model reproduces `path.win32.relative`'s
behaviour, which is the mechanism, not the file system's.

## For the glyphsift port (D3)

The same two hunks apply to `glyphsift/scripts/lib/confine.mjs`: they are the diff of `scripts/lib/confine.mjs` in the commit that
carries this file (the reserved-name regular expression, and the second test in `containment`). The two files are meant to stay
the same apart from their header paragraph, and the case list of the two `confine.test.mjs` files is meant to be identical.
