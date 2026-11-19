#!/usr/bin/env bash
# Tests for scripts/remap-flags.sh (BUG-T2-S6-05): on MINGW/MSYS/CYGWIN it must also emit --remap-path-prefix for the
# native (cygpath -w and -m) forms of the repository root and the cargo home, because rustc embeds D:\a\... there.
# uname and cygpath are stubs on PATH, so this runs on macOS and Linux.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin" "$SCRATCH/root"
cat > "$SCRATCH/bin/uname" <<'S'
#!/bin/sh
echo "${FAKE_UNAME:-Linux}"
S
cat > "$SCRATCH/bin/cygpath" <<'S'
#!/bin/sh
# -w: backslash form, -m: mixed form, both with a fake drive prefix.
mode=$1; p=$2
case "$mode" in
  -w) printf '%s' "D:$p" | tr '/' '\\' ;;
  -m) printf 'D:%s' "$p" ;;
  *) exit 2 ;;
esac
S
chmod +x "$SCRATCH/bin/uname" "$SCRATCH/bin/cygpath"
ROOT=$(cd "$SCRATCH/root" && pwd -P)
flags() { # <uname> -> RUSTFLAGS
  ( cd "$ROOT" && PATH="$SCRATCH/bin:$PATH" FAKE_UNAME="$1" CARGO_HOME="/fake/cargo" RUSTUP_HOME="/fake/rustup" RUSTFLAGS="" \
    bash -c ". '$SCRIPTS_DIR/remap-flags.sh'; printf '%s' \"\$RUSTFLAGS\"" )
}
has() { case "$1" in *"$2"*) echo 1 ;; *) echo 0 ;; esac; }
W=$(printf 'D:%s' "$ROOT" | tr '/' '\\')
M="D:$ROOT"
for u in MINGW64_NT-10.0-20348 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  F=$(flags "$u")
  expect_eq "$u: POSIX root remap kept" 1 "$(has "$F" "--remap-path-prefix=$ROOT=/src")"
  expect_eq "$u: native backslash root remapped" 1 "$(has "$F" "--remap-path-prefix=$W=/src")"
  expect_eq "$u: native mixed root remapped" 1 "$(has "$F" "--remap-path-prefix=$M=/src")"
  expect_eq "$u: native cargo home remapped (backslash)" 1 "$(has "$F" "--remap-path-prefix=D:\\fake\\cargo=/cargo")"
  expect_eq "$u: native cargo home remapped (mixed)" 1 "$(has "$F" "--remap-path-prefix=D:/fake/cargo=/cargo")"
done
F=$(flags Linux)
expect_eq "Linux: POSIX root remap present" 1 "$(has "$F" "--remap-path-prefix=$ROOT=/src")"
expect_eq "Linux: no native forms added" 0 "$(has "$F" "D:")"
F=$(flags Darwin)
expect_eq "Darwin: no native forms added" 0 "$(has "$F" "D:")"
finish
