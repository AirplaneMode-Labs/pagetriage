#!/usr/bin/env bash
# TD-107 (Sprint 7): the workspace version is 1.0.0-rc.1 (SemVer, in Cargo.toml and the npm package) and the wheel, the
# sdist and every filename that Python tools write carry the PEP 440 form 1.0.0rc1. scripts/lib/version.sh is the one place
# that converts; this file tests it, and that Cargo.lock agrees with Cargo.toml for the four workspace crates.
# No network, no build. VERSION_LIB overrides the helper under test (used for the red log).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
LIB=${VERSION_LIB:-$REPO/scripts/lib/version.sh}
if [ ! -f "$LIB" ]; then fail "scripts/lib/version.sh exists"; finish; exit 1; fi
# shellcheck source=../../scripts/lib/version.sh
. "$LIB"

echo "== py_version: SemVer to PEP 440"
expect_eq "2.3.4 stays 2.3.4" "2.3.4" "$(py_version 2.3.4)"
expect_eq "2.3.4-rc.1 is 2.3.4rc1" "2.3.4rc1" "$(py_version 2.3.4-rc.1)"
expect_eq "0.4.0-alpha.1 is 0.4.0a1" "0.4.0a1" "$(py_version 0.4.0-alpha.1)"
expect_eq "0.3.0-beta.2 is 0.3.0b2" "0.3.0b2" "$(py_version 0.3.0-beta.2)"
expect_eq "12.34.56-rc.10 is 12.34.56rc10" "12.34.56rc10" "$(py_version 12.34.56-rc.10)"
for bad in "" "2.3" "2.3.4-rc" "2.3.4-rc.01" "2.3.4-dev.1" "2.3.4+build" "v2.3.4" "02.3.4" "2.3.4-rc.1 " "2.3.4-RC.1" "2.3.4-rc.1-x"; do
  if py_version "$bad" >/dev/null 2>&1; then fail "py_version refuses '$bad'"; else ok "py_version refuses '$bad'"; fi
done

echo "== workspace_version reads Cargo.toml"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
printf '[workspace]\nmembers = []\n\n[workspace.package]\nedition = "2024"\nversion = "9.8.7-rc.3"\n\n[other]\nversion = "0.0.1"\n' > "$S/Cargo.toml"
expect_eq "version of [workspace.package], not of another table" "9.8.7-rc.3" "$(workspace_version "$S/Cargo.toml")"
if workspace_version "$S/nope.toml" >/dev/null 2>&1; then fail "a missing Cargo.toml is an error"; else ok "a missing Cargo.toml is an error"; fi

echo "== the repository: release candidate 1.0.0-rc.1"
V=$(workspace_version "$REPO/Cargo.toml")
expect_eq "Cargo.toml [workspace.package] version" "1.0.0-rc.1" "$V"
expect_eq "the wheel version is 1.0.0rc1" "1.0.0rc1" "$(py_version "$V" 2>/dev/null)"
expect_eq "workspace dependency pagetriage-core carries the same version" 1 "$(grep -cE "^pagetriage-core = \{ path = \"crates/pagetriage-core\", version = \"$V\" \}" "$REPO/Cargo.toml")"
for c in pagetriage-core pagetriage-cli pagetriage-py pagetriage-wasm; do
  got=$(awk -v n="$c" '$0=="name = \"" n "\""{getline; sub(/^version = "/,""); sub(/"$/,""); print; exit}' "$REPO/Cargo.lock")
  expect_eq "Cargo.lock lists $c at $V" "$V" "$got"
done
finish
