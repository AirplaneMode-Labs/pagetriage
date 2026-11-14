# Source this file: appends --remap-path-prefix flags to RUSTFLAGS so built artifacts carry no builder
# path (cargo registry, rustup toolchain, repository root). Existing RUSTFLAGS are kept; ~/.cargo/config
# is never edited. Remapping changes only embedded path strings, not code.
_pt_root=$(pwd)   # source this from the repository root (the scripts cd there first)
RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=${RUSTUP_HOME:-$HOME/.rustup}=/rustup --remap-path-prefix=$_pt_root=/src"
export RUSTFLAGS
unset _pt_root
