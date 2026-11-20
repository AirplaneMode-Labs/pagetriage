#!/usr/bin/env bash
# TD-116 (Sprint 7): the README shows the live demo link in its first screen, as the line
#   Live demo: https://airplanemode-labs.github.io/pagetriage/
# within the first 12 lines (the first 12 lines are what a reader sees without scrolling), and the link is the repository's
# GitHub Pages address. README_FILE overrides the file under test (the planted cases use scratch copies).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
WANT='Live demo: https://airplanemode-labs.github.io/pagetriage/'
check() { # check <file>: prints nothing, exit 0 when the line is within the first 12 lines
  head -n 12 "$1" | grep -qxF "$WANT"
}
README=${README_FILE:-$REPO/README.md}
if check "$README"; then ok "README.md has '$WANT' within its first 12 lines"; else fail "README.md has '$WANT' within its first 12 lines"; fi
expect_eq "the demo URL appears in the README exactly as the Pages address" 1 "$([ "$(grep -cF 'https://airplanemode-labs.github.io/pagetriage/' "$README")" -ge 1 ] && echo 1 || echo 0)"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
printf '# pagetriage\n\nintro\n\n%s\n' "$WANT" > "$S/good.md"
if check "$S/good.md"; then ok "planted: the line on line 5 is accepted"; else fail "planted: the line on line 5 is accepted"; fi
{ printf '# pagetriage\n'; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'filler %s\n' "$i"; done; printf '%s\n' "$WANT"; } > "$S/late.md"
if check "$S/late.md"; then fail "planted: the line on line 14 is refused"; else ok "planted: the line on line 14 is refused"; fi
printf '# pagetriage\n\nLive demo: https://example.org/pagetriage/\n' > "$S/other.md"
if check "$S/other.md"; then fail "planted: another URL is refused"; else ok "planted: another URL is refused"; fi
printf '# pagetriage\n\nSee the Live demo: https://airplanemode-labs.github.io/pagetriage/ now\n' > "$S/inline.md"
if check "$S/inline.md"; then fail "planted: the link inside a sentence is refused (it must be its own line)"; else ok "planted: the link inside a sentence is refused (it must be its own line)"; fi
finish
