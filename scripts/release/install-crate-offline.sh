#!/usr/bin/env bash
# Build and install the command-line tool FROM THE PACKAGED .crate FILES, offline, and prove that no registry supplied the
# '-core' crate (TD-106, Sprint 7; PO item "install the CLI from the packaged crates").
#
#   scripts/release/install-crate-offline.sh <crates-dir> <install-root> <work-dir>
#
#   <crates-dir>    holds pagetriage-core-<version>.crate and pagetriage-cli-<version>.crate (from `cargo package --workspace --locked`)
#   <install-root>  `cargo install --root`: the binary lands in <install-root>/bin/pagetriage (pagetriage.exe on Windows)
#   <work-dir>      must not exist; it receives the vendor directory, the unpacked crates, the build tree and cargo.log
#
# How: third-party crates come from a directory source made by `cargo vendor --locked` of this checkout (the only thing read
# from the checkout); the packaged pagetriage-core crate is unpacked into that directory with a .cargo-checksum.json whose
# "package" hash is the .crate's sha256, so the packaged lock file's checksum for pagetriage-core is satisfied by the file
# that was packaged and by nothing else; the packaged pagetriage-cli crate is unpacked and built with crates-io replaced by
# that directory source, `cargo install --offline --locked --path`. Nothing is fetched, because --offline forbids it, and the
# log is checked as well: no "Downloaded", no index update, and a "Compiling pagetriage-core" line.
# Needs cargo, tar, and sha256sum or shasum. Never publishes, never writes outside <install-root> and <work-dir>.
set -euo pipefail
[ "$#" -eq 3 ] || { echo "usage: $0 <crates-dir> <install-root> <work-dir>" >&2; exit 2; }
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/version.sh"
VERSION=$(workspace_version "$REPO/Cargo.toml")
CRATES=$1; ROOT=$2; WORK=$3
[ -d "$CRATES" ] || { echo "error: $CRATES is not a directory" >&2; exit 2; }
[ ! -e "$WORK" ] || { echo "error: $WORK already exists; pick a fresh directory" >&2; exit 2; }
CORE=$CRATES/pagetriage-core-$VERSION.crate
CLI=$CRATES/pagetriage-cli-$VERSION.crate
[ -f "$CORE" ] && [ -f "$CLI" ] || { echo "error: $CRATES must hold pagetriage-core-$VERSION.crate and pagetriage-cli-$VERSION.crate" >&2; exit 2; }

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
# native: a path in the form cargo (a native program) understands; Git Bash needs the mixed form with a drive letter
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

mkdir -p "$WORK/src" "$ROOT"
WORK=$(cd "$WORK" && pwd)
ROOT=$(cd "$ROOT" && pwd)
LOG=$WORK/cargo.log

echo "== cargo vendor --locked (third-party crates only; this checkout is read, nothing is changed)"
( cd "$REPO" && cargo vendor --locked "$(native "$WORK/vendor")" > "$WORK/vendor.config" 2> "$WORK/vendor.log" ) || { tail -20 "$WORK/vendor.log" >&2; echo "error: cargo vendor failed" >&2; exit 1; }
[ ! -e "$WORK/vendor/pagetriage-core" ] || { echo "error: cargo vendor wrote pagetriage-core (a path dependency must not be vendored)" >&2; exit 1; }
echo "vendored $(ls "$WORK/vendor" | wc -l | tr -d ' ') third-party crates"

echo "== unpack the packaged pagetriage-core crate into the directory source, checksum = the .crate's sha256"
mkdir -p "$WORK/vendor/pagetriage-core"
tar -xzf "$CORE" -C "$WORK/vendor/pagetriage-core" --strip-components=1
printf '{"files":{},"package":"%s"}\n' "$(sha256_of "$CORE")" > "$WORK/vendor/pagetriage-core/.cargo-checksum.json"

echo "== unpack the packaged pagetriage-cli crate"
tar -xzf "$CLI" -C "$WORK/src"
CLIDIR=$WORK/src/pagetriage-cli-$VERSION
[ -f "$CLIDIR/Cargo.toml" ] && [ -f "$CLIDIR/Cargo.lock" ] || { echo "error: the packaged CLI crate lacks Cargo.toml or Cargo.lock" >&2; exit 1; }
mkdir -p "$CLIDIR/.cargo"
cat > "$CLIDIR/.cargo/config.toml" <<TOML
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$(native "$WORK/vendor")"
TOML

echo "== cargo install --offline --locked --path <unpacked cli crate> --root <install root>"
set +e
( cd "$CLIDIR" && cargo install --offline --locked --path "$(native "$CLIDIR")" --root "$(native "$ROOT")" --target-dir "$(native "$WORK/target")" ) > "$LOG" 2>&1
rc=$?
set -e
# CARGO_TERM_COLOR=always puts colour codes into the text; strip them before matching (BSD sed has no \x1b escape)
sed -e "s/$(printf '\033')\[[0-9;]*m//g" "$LOG" > "$WORK/cargo.plain.log"
tail -5 "$WORK/cargo.plain.log"
[ "$rc" = 0 ] || { echo "error: cargo install failed ($rc)" >&2; tail -40 "$WORK/cargo.plain.log" >&2; exit 1; }

# The proofs from the log: normalise path separators before matching.
if grep -qE '^[[:space:]]*Downloaded ' "$WORK/cargo.plain.log"; then echo "error: the log shows a registry download" >&2; grep -E '^[[:space:]]*Downloaded ' "$WORK/cargo.plain.log" >&2; exit 1; fi
if grep -qE 'Downloaded pagetriage-core|Updating .*index|Locking ' "$WORK/cargo.plain.log"; then echo "error: the log shows an index update or a download of pagetriage-core" >&2; exit 1; fi
grep -qE "Compiling pagetriage-core v$VERSION" "$WORK/cargo.plain.log" || { echo "error: the log has no 'Compiling pagetriage-core v$VERSION' line" >&2; exit 1; }
grep -qE "Compiling pagetriage-cli v$VERSION" "$WORK/cargo.plain.log" || { echo "error: the log has no 'Compiling pagetriage-cli v$VERSION' line" >&2; exit 1; }
BIN=$ROOT/bin/pagetriage
[ -f "$BIN" ] || BIN=$ROOT/bin/pagetriage.exe
[ -f "$BIN" ] || { echo "error: no pagetriage binary under $ROOT/bin" >&2; exit 1; }
echo "ok: pagetriage-core v$VERSION was compiled from $(basename "$CORE") (sha256 $(sha256_of "$CORE")), no registry download, installed to $BIN"
