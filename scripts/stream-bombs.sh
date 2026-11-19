#!/usr/bin/env bash
# Run the CLI's stream accounting over the synthetic bombs and log, for each: the input size, the verdict
# and reason, the wall time and the peak resident memory, with a pass or fail against the budget
# "peak <= input size + 64 MiB" (S1-107). The bombs are generated into a scratch folder by
# `examples/gen_stream_bombs.rs` and are never committed.
#
#   scripts/stream-bombs.sh [workdir]        workdir defaults to a fresh temporary folder; it is removed at the end
#   STREAMS_CSV=docs/benchmarks/streams-native.csv scripts/stream-bombs.sh     also writes the rows as CSV
#
# Needs /usr/bin/time (BSD `-l` on macOS, GNU `-v` on Linux). The numbers are for this machine; none of them is
# an 8 GB laptop figure (not measured on 8 GB).
set -euo pipefail
cd "$(dirname "$0")/.."

work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/pagetriage-bombs.XXXXXX")}
mkdir -p "$work"
cargo build --locked --release -p pagetriage-cli -p pagetriage-core --features pagetriage-core/pdf --example gen_stream_bombs >/dev/null 2>&1 || cargo build --locked --release -p pagetriage-cli >/dev/null
cargo run --locked --release -q -p pagetriage-core --features pdf --example gen_stream_bombs -- "$work" >/dev/null
bin=${CARGO_TARGET_DIR:-target}/release/pagetriage
[ -x "$bin" ] || { echo "error: $bin not built" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) time_args=(-l) ;;
  *) time_args=(-v) ;;
esac
peak_bytes() { # parses /usr/bin/time output on stdin: BSD gives bytes, GNU gives KiB
  if [ "$(uname -s)" = Darwin ]; then awk '/maximum resident set size/ {print $1}'; else awk '/Maximum resident set size/ {print $NF * 1024}'; fi
}

budget_extra=$((64 * 1024 * 1024))
fail=0
machine="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //' || true) ($(uname -s) $(uname -r) $(uname -m), $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?') cores)"
commit=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
[ -n "$(git status --porcelain 2>/dev/null)" ] && commit="$commit-dirty"
if [ -n "${STREAMS_CSV:-}" ]; then
  echo 'machine,command,commit,file,input_bytes,verdict,reason,wall_ms,peak_rss_bytes,budget_bytes,within_budget,eight_gb_laptop' > "$STREAMS_CSV"
fi
printf '%-28s %12s %-8s %-20s %9s %14s %s\n' file input_bytes verdict reason wall_ms peak_rss_bytes budget
for f in "$work"/*.pdf; do
  name=$(basename "$f")
  size=$(wc -c < "$f" | tr -d ' ')
  start=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  set +e
  /usr/bin/time "${time_args[@]}" "$bin" streams "$f" > "$work/out.json" 2> "$work/time.txt"
  set -e
  end=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
  peak=$(peak_bytes < "$work/time.txt")
  verdict=$(sed -E 's/.*"verdict":"([a-z]+)".*/\1/' "$work/out.json")
  reason=$(sed -E 's/.*"reason":"([a-z_]*)".*/\1/' "$work/out.json")
  limit=$((size + budget_extra))
  if [ "$peak" -le "$limit" ]; then status="ok (<= input + 64 MiB)"; else status="OVER (> input + 64 MiB)"; fail=1; fi
  printf '%-28s %12s %-8s %-20s %9s %14s %s\n' "$name" "$size" "$verdict" "${reason:--}" "$(( (end - start) / 1000000 ))" "$peak" "$status"
  if [ -n "${STREAMS_CSV:-}" ]; then
    within=$([ "$peak" -le "$limit" ] && echo true || echo false)
    printf '"%s","scripts/stream-bombs.sh (cargo build --release; /usr/bin/time %s target/release/pagetriage streams FILE)",%s,%s,%s,%s,%s,%s,%s,%s,%s,not measured on 8 GB\n' \
      "$machine" "${time_args[*]}" "$commit" "$name" "$size" "$verdict" "${reason:-}" "$(( (end - start) / 1000000 ))" "$peak" "$limit" "$within" >> "$STREAMS_CSV"
  fi
done
rm -f "$work"/*.pdf "$work/out.json" "$work/time.txt"
rmdir "$work" 2>/dev/null || true
exit $fail
