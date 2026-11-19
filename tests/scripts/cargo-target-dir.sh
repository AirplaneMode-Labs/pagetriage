#!/usr/bin/env bash
# BUG-T2-S5-14: scripts/build-wasm.sh honours CARGO_TARGET_DIR.
#
# The script read the raw .wasm from a literal `target/`, so with CARGO_TARGET_DIR pointing elsewhere (CI caches and shared
# build folders do that) cargo built into one place and the script looked in another. This test runs the script in a
# scratch checkout with stubbed cargo, wasm-bindgen and wasm-opt (no network, nothing built). The cargo stub writes the
# raw module where real cargo would, which is $CARGO_TARGET_DIR/wasm32-unknown-unknown/wasm/, or target/ when the variable
# is unset; the wasm-bindgen stub fails if the file it is given is not there.
#
#   - an absolute CARGO_TARGET_DIR outside the checkout works, and the package is written;
#   - a relative one is read relative to the checkout root, where cargo runs;
#   - an unset one still uses target/;
#   - a set-but-empty one is treated as unset, as cargo does.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

new_scratch
trap 'rm -rf "$SCRATCH"' EXIT
cp "$SCRIPTS_DIR/build-wasm.sh" "$SCRIPTS_DIR/remap-flags.sh" "$SCRATCH/scripts/"
PIN=$(sed -n 's/^wasm-bindgen = "=\(.*\)"/\1/p' "$SCRATCH/crates/pagetriage-wasm/Cargo.toml")
[ -n "$PIN" ] || fail "the wasm-bindgen pin is readable from the crate manifest"

cat > "$SCRATCH/bin/cargo" <<'S'
#!/usr/bin/env bash
dest="${CARGO_TARGET_DIR:-target}/wasm32-unknown-unknown/wasm"
mkdir -p "$dest" && printf 'stub wasm' > "$dest/pagetriage_wasm.wasm"
S
cat > "$SCRATCH/bin/wasm-bindgen" <<S
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then echo "wasm-bindgen $PIN"; exit 0; fi
out=""; raw=""
while [ \$# -gt 0 ]; do case "\$1" in --out-dir) out=\$2; shift 2 ;; --target|--out-name) shift 2 ;; *) raw=\$1; shift ;; esac; done
[ -f "\$raw" ] || { echo "stub wasm-bindgen: no such file: \$raw" >&2; exit 1; }
mkdir -p "\$out" && cp "\$raw" "\$out/pagetriage_bg.wasm" && : > "\$out/pagetriage.js"
S
cat > "$SCRATCH/bin/wasm-opt" <<'S'
#!/usr/bin/env bash
in=""; out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; --*|-O*) shift ;; *) in=$1; shift ;; esac; done
[ "$in" = "$out" ] || cp "$in" "$out"
S
chmod +x "$SCRATCH/bin/"*

run() { ( cd "$SCRATCH" && env "$@" PATH="$SCRATCH/bin:$PATH" bash scripts/build-wasm.sh ) >"$SCRATCH/log.txt" 2>&1; echo $?; }

rm -rf "$SCRATCH/target" "$SCRATCH/dist"
ELSEWHERE=$(mktemp -d "${TMPDIR:-/tmp}/pt-ctd.XXXXXX")
trap 'rm -rf "$SCRATCH" "$ELSEWHERE"' EXIT
expect_eq "absolute CARGO_TARGET_DIR outside the checkout: exit 0" 0 "$(run CARGO_TARGET_DIR="$ELSEWHERE")"
expect_eq "  the raw module was read from CARGO_TARGET_DIR" yes "$([ -f "$ELSEWHERE/wasm32-unknown-unknown/wasm/pagetriage_wasm.wasm" ] && echo yes || echo no)"
expect_eq "  the package was written" yes "$([ -f "$SCRATCH/dist/wasm/web/pagetriage_bg.wasm" ] && [ -f "$SCRATCH/dist/wasm/nodejs/pagetriage_bg.wasm" ] && echo yes || echo no)"
expect_eq "  nothing was written to target/" no "$([ -e "$SCRATCH/target" ] && echo yes || echo no)"

rm -rf "$SCRATCH/dist"
expect_eq "relative CARGO_TARGET_DIR (against the checkout root): exit 0" 0 "$(run CARGO_TARGET_DIR=rel-tgt)"
expect_eq "  the raw module is under the relative folder" yes "$([ -f "$SCRATCH/rel-tgt/wasm32-unknown-unknown/wasm/pagetriage_wasm.wasm" ] && echo yes || echo no)"
expect_eq "  the package was written" yes "$([ -f "$SCRATCH/dist/wasm/web/pagetriage_bg.wasm" ] && echo yes || echo no)"

rm -rf "$SCRATCH/dist" "$SCRATCH/target"
expect_eq "unset CARGO_TARGET_DIR still uses target/: exit 0" 0 "$(run -u CARGO_TARGET_DIR)"
expect_eq "  the raw module is under target/" yes "$([ -f "$SCRATCH/target/wasm32-unknown-unknown/wasm/pagetriage_wasm.wasm" ] && echo yes || echo no)"

rm -rf "$SCRATCH/dist" "$SCRATCH/target"
expect_eq "empty CARGO_TARGET_DIR is treated as unset: exit 0" 0 "$(run CARGO_TARGET_DIR=)"
expect_eq "  the raw module is under target/" yes "$([ -f "$SCRATCH/target/wasm32-unknown-unknown/wasm/pagetriage_wasm.wasm" ] && echo yes || echo no)"
finish
