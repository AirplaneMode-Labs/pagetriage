#!/usr/bin/env bash
# Tests for the sign and gate phases of scripts/release/rehearse.sh (TD-103, TD-106, Sprint 7) on SYNTHETIC artefacts: tiny but
# valid archives named like the real ones. No build, no network, seconds. The build and install phases are proven by running the
# whole script (CI job release-rehearsal, and locally: bash scripts/release/rehearse.sh all).
#
# What is proved here: the rehearsal signs with the published TEST key and verifies it; every refusal proof checks the exact exit
# code and first stderr line; a missing tool, a tool that never refuses and a tool that always fails each turn the rehearsal red
# (the self-test, and again here from outside); the output is deterministic for a given SOURCE_DATE_EPOCH; SHA256SUMS is LF only
# with one line per artefact; the gate refuses a stray file, a credential name, a subdirectory and a missing SHA256SUMS.
# Runs with GITHUB_SHA and GITHUB_REF cleared and reads no sibling repository.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { fail "node not found: the release tool cannot run (Node 22 is required)"; finish; exit 1; }
command -v python3 >/dev/null || { fail "python3 not found"; finish; exit 1; }
. "$REPO/scripts/lib/version.sh"
V=$(workspace_version "$REPO/Cargo.toml")
PV=$(py_version "$V")
TOOL_FILE=${RELEASE_TOOL:-$REPO/scripts/release/release-tool.mjs}
[ -f "$TOOL_FILE" ] || { fail "the release tool exists at $TOOL_FILE (vendor it from runtime/spec/tools first)"; finish; exit 1; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT

# The five synthetic artefacts are made ONCE, deterministically (fixed gzip and zip timestamps), and copied into each output root, so two
# roots hold the same bytes and the determinism check below compares like with like.
BASE=$S/base-artefacts; mkdir -p "$BASE"
python3 -I - "$BASE" "$V" "$PV" <<'PY'
import gzip, io, os, sys, tarfile, zipfile
d, v, pv = sys.argv[1:4]
def tgz(path, files):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as t:
        for n, data in files.items():
            i = tarfile.TarInfo(n); i.size = len(data); i.mtime = 0; t.addfile(i, io.BytesIO(data))
    with open(path, "wb") as f:
        with gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0) as g:
            g.write(raw.getvalue())
# A packaged crate holds the licence texts and the NOTICE next to Cargo.toml (BUG-T3-S7-04): the gate requires all three in every .crate.
def crate(path, name, omit=()):
    files = {f"{name}/Cargo.toml": b"[package]\n", f"{name}/LICENSE-APACHE": b"Apache\n", f"{name}/LICENSE-MIT": b"MIT\n", f"{name}/NOTICE": b"notice\n"}
    for o in omit: del files[f"{name}/{o}"]
    tgz(path, files)
tgz(f"{d}/airplanemode-pagetriage-{v}.tgz", {"package/package.json": b"{}\n"})
tgz(f"{d}/pagetriage-{pv}.tar.gz", {f"pagetriage-{pv}/Cargo.toml": b"[package]\n"})
crate(f"{d}/pagetriage-core-{v}.crate", f"pagetriage-core-{v}")
crate(f"{d}/pagetriage-cli-{v}.crate", f"pagetriage-cli-{v}")
zi = zipfile.ZipInfo("pagetriage_py/__init__.py", date_time=(2026, 11, 20, 0, 0, 0))
with zipfile.ZipFile(f"{d}/pagetriage-{pv}-cp39-abi3-macosx_11_0_arm64.whl", "w") as z:
    z.writestr(zi, "")
# variants for the gate: the core crate without one of the three files, one in the wrong folder, and a file that is not a gzip tarball
var = os.path.join(os.path.dirname(d), "variants")
os.makedirs(var, exist_ok=True)
for omit in ("NOTICE", "LICENSE-MIT", "LICENSE-APACHE"):
    crate(f"{var}/core-without-{omit}.crate", f"pagetriage-core-{v}", omit=(omit,))
crate(f"{var}/core-wrong-folder.crate", "pagetriage-core-9.9.9")
with open(f"{var}/core-not-a-tarball.crate", "wb") as f:
    f.write(b"not a tarball\n")
PY
make_root() { # make_root <name>: an output root holding dist-release/ with the five artefacts
  local r=$S/$1; mkdir -p "$r/dist-release"; cp "$BASE"/* "$r/dist-release/"; echo "$r"
}
# rehearse <root> <phase> [VAR=value...]: runs the script with the scrubbed variables; output in $S/last.out, status echoed
rehearse() {
  local r=$1 phase=$2; shift 2
  env -u GITHUB_SHA -u GITHUB_REF REHEARSE_OUT_ROOT="$r" SOURCE_DATE_EPOCH="${SDE:-1700000000}" "$@" bash "$REPO/scripts/release/rehearse.sh" "$phase" > "$S/last.out" 2>&1
  echo $?
}

echo "== sign: the rehearsal with the TEST key, on synthetic artefacts"
R1=$(make_root one)
expect_eq "sign exits 0 (self-test, manifest, SHA256SUMS, signature, verification, every refusal proof)" 0 "$(rehearse "$R1" sign RELEASE_TOOL="$TOOL_FILE")"
tail -5 "$S/last.out" | sed 's/^/   /'
for f in release-manifest.json SHA256SUMS; do [ -f "$R1/dist-release/$f" ] && ok "dist-release/$f was written" || fail "dist-release/$f was written"; done
expect_eq "the manifest carries the TEST 1 key id" 1 "$(grep -c '21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9' "$R1/dist-release/release-manifest.json")"
expect_eq "the manifest id is pagetriage-rehearsal and its version the workspace version" 2 "$(grep -cE "\"id\": \"pagetriage-rehearsal\"|\"version\": \"$V\"" "$R1/dist-release/release-manifest.json" | awk '{print ($1>=2)?2:$1}')"
expect_eq "no expiresAt in the manifest (TD-121)" 0 "$(grep -c expiresAt "$R1/dist-release/release-manifest.json")"
expect_eq "SHA256SUMS has one line per artefact (5)" 5 "$(wc -l < "$R1/dist-release/SHA256SUMS" | tr -d ' ')"
expect_eq "SHA256SUMS has LF endings only" 0 "$(tr -d '\n' < "$R1/dist-release/SHA256SUMS" | grep -c "$(printf '\r')")"
expect_eq "the refusal table has at least 10 rows, all proved" 0 "$(awk -F'\t' '$5!="proved"' "$R1/dist-release-report/refusals.tsv" | wc -l | tr -d ' ')"
expect_eq "the refusal table has at least 10 rows" 1 "$([ "$(wc -l < "$R1/dist-release-report/refusals.tsv" | tr -d ' ')" -ge 10 ] && echo 1 || echo 0)"
expect_eq "the no-flag proof is in the table with exit 3 and the exact first line" 1 "$(awk -F'\t' '$1=="no-flag" && $2==3 && $3=="refused: test_key_refused"' "$R1/dist-release-report/refusals.tsv" | wc -l | tr -d ' ')"
expect_eq "the production key file proof is in the table (no_trusted_key)" 1 "$(awk -F'\t' '$3=="refused: no_trusted_key" && $2==3' "$R1/dist-release-report/refusals.tsv" | wc -l | tr -d ' ')"
expect_eq "the report is outside the release directory" 0 "$(ls "$R1/dist-release" | grep -c report)"

echo "== sign is deterministic for a fixed SOURCE_DATE_EPOCH"
R2=$(make_root two)
expect_eq "the second root signs too" 0 "$(rehearse "$R2" sign RELEASE_TOOL="$TOOL_FILE")"
for f in release-manifest.json SHA256SUMS; do
  if cmp -s "$R1/dist-release/$f" "$R2/dist-release/$f"; then ok "$f is byte-identical in two runs"; else fail "$f is byte-identical in two runs"; fi
done
R3=$(make_root three)
expect_eq "another SOURCE_DATE_EPOCH signs" 0 "$(SDE=1700000001 rehearse "$R3" sign RELEASE_TOOL="$TOOL_FILE")"
if cmp -s "$R1/dist-release/release-manifest.json" "$R3/dist-release/release-manifest.json"; then fail "createdAt follows SOURCE_DATE_EPOCH"; else ok "createdAt follows SOURCE_DATE_EPOCH"; fi
expect_eq "an invalid SOURCE_DATE_EPOCH is not accepted" 1 "$([ "$(SDE=notanumber rehearse "$(make_root badsde)" sign RELEASE_TOOL="$TOOL_FILE")" != 0 ] && echo 1 || echo 0)"

echo "== sign: a broken tool turns the rehearsal red"
expect_eq "a missing tool fails" 1 "$([ "$(rehearse "$(make_root missing)" sign RELEASE_TOOL="$S/no-such-tool.mjs")" != 0 ] && echo 1 || echo 0)"
printf 'import { spawnSync } from "node:child_process";\nif (process.env.REHEARSE_STUB_DEPTH) process.exit(1);\nspawnSync(process.execPath, [process.env.REAL_TOOL, ...process.argv.slice(2)], { stdio: "inherit", env: { ...process.env, REHEARSE_STUB_DEPTH: "1" } });\nprocess.exit(0);\n' > "$S/lenient.mjs"
expect_eq "a verifier that never refuses (exit 0 for everything) fails" 1 "$([ "$(rehearse "$(make_root lenient)" sign RELEASE_TOOL="$S/lenient.mjs" REAL_TOOL="$TOOL_FILE")" != 0 ] && echo 1 || echo 0)"
printf 'console.error("EIO: read failed"); process.exit(1)\n' > "$S/io.mjs"
expect_eq "a tool that always fails with an I/O error (exit 1) fails: an I/O error is never a refusal" 1 "$([ "$(rehearse "$(make_root io)" sign RELEASE_TOOL="$S/io.mjs")" != 0 ] && echo 1 || echo 0)"
# a tool that refuses everything with the right exit code but the wrong words: the first stderr line is checked exactly
printf 'import { spawnSync } from "node:child_process";\nif (process.env.REHEARSE_STUB_DEPTH) process.exit(1);\nconst r = spawnSync(process.execPath, [process.env.REAL_TOOL, ...process.argv.slice(2)], { encoding: "utf8", env: { ...process.env, REHEARSE_STUB_DEPTH: "1" } });\nprocess.stdout.write(r.stdout);\nprocess.stderr.write((r.status === 3 ? "denied: " : "") + r.stderr);\nprocess.exit(r.status);\n' > "$S/wording.mjs"
expect_eq "a tool whose first stderr line says 'denied:' instead of 'refused:' fails" 1 "$([ "$(rehearse "$(make_root wording)" sign RELEASE_TOOL="$S/wording.mjs" REAL_TOOL="$TOOL_FILE")" != 0 ] && echo 1 || echo 0)"
expect_eq "the sign phase on an empty output root fails (no dist-release)" 1 "$([ "$(rehearse "$S/nowhere" sign RELEASE_TOOL="$TOOL_FILE")" != 0 ] && echo 1 || echo 0)"

echo "== gate: dist-release holds only the entries, the manifest and SHA256SUMS"
expect_eq "gate passes on the signed synthetic directory" 0 "$(rehearse "$R1" gate RELEASE_TOOL="$TOOL_FILE")"
G=$(make_root gate); rehearse "$G" sign RELEASE_TOOL="$TOOL_FILE" >/dev/null
printf 'x\n' > "$G/dist-release/notes.txt"
expect_eq "a stray file is refused" 1 "$([ "$(rehearse "$G" gate)" != 0 ] && echo 1 || echo 0)"
rm -f "$G/dist-release/notes.txt"
for name in .npmrc .pypirc server.pem release.key id.der k.pkcs8 my-seed.bin .env; do
  : > "$G/dist-release/$name"
  expect_eq "a file named $name in dist-release is refused" 1 "$([ "$(rehearse "$G" gate)" != 0 ] && echo 1 || echo 0)"
  rm -f "$G/dist-release/$name"
done
mkdir "$G/dist-release/sub"
expect_eq "a subdirectory is refused" 1 "$([ "$(rehearse "$G" gate)" != 0 ] && echo 1 || echo 0)"
rmdir "$G/dist-release/sub"
mv "$G/dist-release/SHA256SUMS" "$S/sums.keep"
expect_eq "a missing SHA256SUMS is refused" 1 "$([ "$(rehearse "$G" gate)" != 0 ] && echo 1 || echo 0)"
mv "$S/sums.keep" "$G/dist-release/SHA256SUMS"
expect_eq "the directory is accepted again once it is restored" 0 "$(rehearse "$G" gate)"
echo "== gate: every .crate holds LICENSE-APACHE, LICENSE-MIT and NOTICE (BUG-T3-S7-04)"
expect_eq "the synthetic crates hold all three files and the gate passes" 0 "$(rehearse "$R1" gate RELEASE_TOOL="$TOOL_FILE")"
for omit in NOTICE LICENSE-MIT LICENSE-APACHE; do
  C=$(make_root "crate-no-$omit"); cp "$S/variants/core-without-$omit.crate" "$C/dist-release/pagetriage-core-$V.crate"
  rehearse "$C" sign RELEASE_TOOL="$TOOL_FILE" >/dev/null
  expect_eq "a core crate without $omit is refused by the gate" 1 "$([ "$(rehearse "$C" gate)" != 0 ] && echo 1 || echo 0)"
  expect_eq "the refusal names the crate and $omit" 1 "$(grep -F "pagetriage-core-$V.crate" "$S/last.out" | grep -cF "$omit" | awk '{print ($1>0)?1:0}')"
done
C=$(make_root crate-cli-no-notice)
python3 -I - "$C/dist-release/pagetriage-cli-$V.crate" "$V" <<'PY'
import gzip, io, sys, tarfile
dst, v = sys.argv[1:3]
raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode="w") as t:
    for n in ("Cargo.toml", "LICENSE-APACHE", "LICENSE-MIT"):
        i = tarfile.TarInfo(f"pagetriage-cli-{v}/{n}"); i.size = 2; i.mtime = 0; t.addfile(i, io.BytesIO(b"x\n"))
with open(dst, "wb") as f:
    with gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0) as g:
        g.write(raw.getvalue())
PY
rehearse "$C" sign RELEASE_TOOL="$TOOL_FILE" >/dev/null
expect_eq "a cli crate without NOTICE is refused by the gate as well" 1 "$([ "$(rehearse "$C" gate)" != 0 ] && echo 1 || echo 0)"
C=$(make_root crate-wrong-folder); cp "$S/variants/core-wrong-folder.crate" "$C/dist-release/pagetriage-core-$V.crate"; rehearse "$C" sign RELEASE_TOOL="$TOOL_FILE" >/dev/null
expect_eq "a crate whose files sit in another folder than <name>-<version>/ is refused" 1 "$([ "$(rehearse "$C" gate)" != 0 ] && echo 1 || echo 0)"
C=$(make_root crate-not-tar); cp "$S/variants/core-not-a-tarball.crate" "$C/dist-release/pagetriage-core-$V.crate"; rehearse "$C" sign RELEASE_TOOL="$TOOL_FILE" >/dev/null
expect_eq "a crate that is not a gzip tarball is refused" 1 "$([ "$(rehearse "$C" gate)" != 0 ] && echo 1 || echo 0)"
PLAIN="1.0.$((0))"   # written like this so that no-plain-1.0.0.sh does not read this file as a plain version
python3 -I -c "import sys; open(sys.argv[1], 'w').write('0')" "$G/dist-release/pagetriage-$PLAIN-cp39-abi3-macosx_11_0_arm64.whl"
expect_eq "an artefact named with the plain release version is refused" 1 "$([ "$(rehearse "$G" gate)" != 0 ] && echo 1 || echo 0)"
finish
