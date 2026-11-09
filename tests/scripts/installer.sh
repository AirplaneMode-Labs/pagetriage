#!/usr/bin/env bash
# Tests for scripts/install-wasm-tools.sh: no network (curl and uname are stubs), nothing installed.
#   tests/scripts/installer.sh            (SCRIPTS_DIR=<dir> to test another copy of the scripts)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

new_scratch
trap 'rm -rf "$SCRATCH"' EXIT
cp "$SCRIPTS_DIR/install-wasm-tools.sh" "$SCRATCH/scripts/"
CURL_LOG=$SCRATCH/curl.log
# curl stub: records its arguments and fails, so any download attempt is both visible and harmless.
cat > "$SCRATCH/bin/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$CURL_LOG"
exit 22
STUB
# uname stub: FAKE_S and FAKE_M stand in for the platform.
cat > "$SCRATCH/bin/uname" <<'STUB'
#!/usr/bin/env bash
case "$1" in -s) echo "${FAKE_S:-Linux}" ;; -m) echo "${FAKE_M:-x86_64}" ;; *) echo "${FAKE_S:-Linux}" ;; esac
STUB
chmod +x "$SCRATCH/bin/curl" "$SCRATCH/bin/uname"

# run <root> [VAR=value ...]: run the installer under the stubs, print its exit code.
run() {
  local root=$1; shift
  : > "$CURL_LOG"
  env PATH="$SCRATCH/bin:$PATH" INSTALL_ROOT="$root" "$@" bash "$SCRATCH/scripts/install-wasm-tools.sh" >/dev/null 2>&1
  echo $?
}

# 1. Unknown binaryen version: non-zero, no curl call, install root stays empty.
ROOT=$SCRATCH/root1
rc=$(run "$ROOT" BINARYEN_VERSION=999)
[ "$rc" -ne 0 ] && ok "BINARYEN_VERSION=999 exits non-zero" || fail "BINARYEN_VERSION=999 exits non-zero (got $rc)"
expect_eq "BINARYEN_VERSION=999 makes no curl call" 0 "$(wc -l < "$CURL_LOG" | tr -d ' ')"
expect_eq "BINARYEN_VERSION=999 installs nothing" 0 "$(find "$ROOT" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

# 2. Unknown wasm-bindgen version: same.
ROOT=$SCRATCH/root2
sed -i.bak 's/^wasm-bindgen = "=.*"/wasm-bindgen = "=999.0.0"/' "$SCRATCH/crates/pagetriage-wasm/Cargo.toml"
rc=$(run "$ROOT")
[ "$rc" -ne 0 ] && ok "wasm-bindgen 999.0.0 exits non-zero" || fail "wasm-bindgen 999.0.0 exits non-zero (got $rc)"
expect_eq "wasm-bindgen 999.0.0 makes no curl call" 0 "$(wc -l < "$CURL_LOG" | tr -d ' ')"
cp "$REPO/crates/pagetriage-wasm/Cargo.toml" "$SCRATCH/crates/pagetriage-wasm/Cargo.toml"

# 3. Windows on arm64 is unsupported: exit 1, no curl call.
rc=$(run "$SCRATCH/root3" FAKE_S=MINGW64_NT-10.0-22631 FAKE_M=aarch64)
expect_eq "aarch64 Windows exits 1" 1 "$rc"
expect_eq "aarch64 Windows makes no curl call" 0 "$(wc -l < "$CURL_LOG" | tr -d ' ')"

# 4. Windows x86_64 asks for the msvc wasm-bindgen asset (the stub then fails the download).
rc=$(run "$SCRATCH/root4" FAKE_S=MINGW64_NT-10.0-22631 FAKE_M=x86_64)
[ "$rc" -ne 0 ] && ok "Windows x86_64 stops at the failing stub download" || fail "Windows x86_64 stops at the failing stub download"
if grep -q 'wasm-bindgen-[0-9.]*-x86_64-pc-windows-msvc.tar.gz' "$CURL_LOG"; then ok "Windows x86_64 requests the msvc wasm-bindgen asset"; else fail "Windows x86_64 requests the msvc wasm-bindgen asset"; fi

# 5. The digest table has exactly the 8 pinned rows, each a 64-hex SHA-256.
rows=$(grep -cE '^[[:space:]]+(wasm-bindgen|binaryen)-[^)]*\)[[:space:]]+echo [0-9a-f]{64} ;;$' "$SCRIPTS_DIR/install-wasm-tools.sh")
expect_eq "digest table has exactly 8 pinned rows" 8 "$rows"
for d in 79e348c169d0c10c0b287647f1e753d0985353ca96800bc29be8f4261baf13e6 17a2cbeac6b5693c5fbafab3838d3c65fd9c1eb38b05f5baec6c657e8c84995b; do
  grep -q "$d" "$SCRIPTS_DIR/install-wasm-tools.sh" && ok "Windows digest ${d:0:8} pinned" || fail "Windows digest ${d:0:8} pinned"
done
finish
