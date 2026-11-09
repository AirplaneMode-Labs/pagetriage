#!/usr/bin/env bash
# Tests for the WASM_OUT guard in scripts/build-wasm.sh (it runs rm -rf on that path). Refused values
# exit 2 and leave a sentinel directory alone; a safe relative value gets past the guard (the stubbed
# wasm-bindgen then stops the script, so nothing is built).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

new_scratch
trap 'rm -rf "$SCRATCH"' EXIT
cp "$SCRIPTS_DIR/build-wasm.sh" "$SCRATCH/scripts/"
# wasm-bindgen stub reports a version that mismatches the pin, so a script that passes the guard exits 1.
printf '#!/usr/bin/env bash\necho "wasm-bindgen 0.0.0"\n' > "$SCRATCH/bin/wasm-bindgen"
chmod +x "$SCRATCH/bin/wasm-bindgen"
VICTIM=$SCRATCH/victim
mkdir -p "$VICTIM"; echo keep > "$VICTIM/file"

run() { env PATH="$SCRATCH/bin:$PATH" "$@" bash "$SCRATCH/scripts/build-wasm.sh" >/dev/null 2>&1; echo $?; }

expect_eq "absolute WASM_OUT exits 2" 2 "$(run WASM_OUT="$VICTIM")"
expect_eq "absolute WASM_OUT leaves the directory alone" keep "$(cat "$VICTIM/file" 2>/dev/null)"
expect_eq "empty WASM_OUT exits 2" 2 "$(run WASM_OUT=)"
expect_eq "'..' WASM_OUT exits 2" 2 "$(run WASM_OUT=..)"
expect_eq "'../x' WASM_OUT exits 2" 2 "$(run WASM_OUT=../x)"
expect_eq "'a/../..' WASM_OUT exits 2" 2 "$(run WASM_OUT=a/../..)"
# Windows-style values (Git Bash on windows-latest): drive-letter paths and any backslash (BUG-T2-S2-14).
expect_eq "'C:/Windows/x' WASM_OUT exits 2" 2 "$(run WASM_OUT=C:/Windows/x)"
expect_eq "'C:x' WASM_OUT exits 2" 2 "$(run WASM_OUT=C:x)"
expect_eq "'c:\\x' WASM_OUT exits 2" 2 "$(run WASM_OUT='c:\x')"
expect_eq "'..\\x' WASM_OUT exits 2" 2 "$(run WASM_OUT='..\x')"
expect_eq "'a\\..\\b' WASM_OUT exits 2" 2 "$(run WASM_OUT='a\..\b')"
expect_eq "'dist\\ok' WASM_OUT exits 2" 2 "$(run WASM_OUT='dist\ok')"
expect_eq "backslash refusals leave the directory alone" keep "$(cat "$VICTIM/file" 2>/dev/null)"
expect_eq "relative WASM_OUT passes the guard" 1 "$(run WASM_OUT=dist/test-out)"
expect_eq "unset WASM_OUT passes the guard" 1 "$(env -u WASM_OUT PATH="$SCRATCH/bin:$PATH" bash "$SCRATCH/scripts/build-wasm.sh" >/dev/null 2>&1; echo $?)"
finish
