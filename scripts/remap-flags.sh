# Source this file: appends --remap-path-prefix flags to RUSTFLAGS so built artifacts carry no builder
# path (cargo registry, rustup toolchain, repository root). Existing RUSTFLAGS are kept; ~/.cargo/config
# is never edited. Remapping changes only embedded path strings, not code.
_pt_root=$(pwd)   # source this from the repository root (the scripts cd there first)
RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=${RUSTUP_HOME:-$HOME/.rustup}=/rustup --remap-path-prefix=$_pt_root=/src"
export RUSTFLAGS
# Git Bash / MSYS / Cygwin: rustc embeds native paths (D:\a\repo\repo, C:\Users\runneradmin\.cargo), so remap the
# native backslash (cygpath -w) and mixed (cygpath -m) forms as well as the POSIX one (BUG-T2-S6-05).
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v cygpath >/dev/null 2>&1; then
      for _pt_pair in "$_pt_root=/src" "${CARGO_HOME:-$HOME/.cargo}=/cargo" "${RUSTUP_HOME:-$HOME/.rustup}=/rustup"; do
        _pt_from=${_pt_pair%%=*}; _pt_to=${_pt_pair#*=}
        for _pt_mode in -w -m; do
          _pt_native=$(cygpath "$_pt_mode" "$_pt_from" 2>/dev/null || true)
          [ -n "$_pt_native" ] && RUSTFLAGS="$RUSTFLAGS --remap-path-prefix=$_pt_native=$_pt_to"
        done
      done
    fi ;;
esac
export RUSTFLAGS
unset _pt_root _pt_pair _pt_from _pt_to _pt_mode _pt_native
