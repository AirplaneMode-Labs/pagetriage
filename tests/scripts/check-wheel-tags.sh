#!/usr/bin/env bash
# tests/python/test_check_wheel.py: the wheel check compares tags as expanded sets (CI lesson of 18 Nov 2026) and checks the
# licence files, NOTICE, sizes and the absence of scripts and entry points. Needs only python3.
#   CHECK_WHEEL_SCRIPT=<file> tests/scripts/check-wheel-tags.sh      run against another script (the red log uses a stub)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { fail "python3 not found: check-wheel-tags.sh cannot run"; finish; exit 1; }
out=$(cd "$REPO" && python3 -I tests/python/test_check_wheel.py 2>&1); rc=$?
echo "$out" | tail -5
expect_eq "tests/python/test_check_wheel.py passes" 0 "$rc"
finish
