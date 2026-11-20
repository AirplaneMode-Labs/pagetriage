#!/usr/bin/env bash
# Sourced helpers for the version of this workspace (TD-107, Sprint 7). Nothing here touches the network or the tree.
#
#   . scripts/lib/version.sh
#   workspace_version [Cargo.toml]   the SemVer in [workspace.package] (default: Cargo.toml in the current directory)
#   py_version <semver>              the PEP 440 form Python tools write: 2.3.4-rc.1 -> 2.3.4rc1, 0.4.0-alpha.1 -> 0.4.0a1,
#                                    0.3.0-beta.2 -> 0.3.0b2, 2.3.4 -> 2.3.4; anything else is an error (exit 1)
#
# The npm package and the crates keep the SemVer form; the wheel and the sdist filenames (maturin) carry the PEP 440 form.
# A test or a script that compares a version with a filename must go through py_version.

workspace_version() {
  local file=${1:-Cargo.toml} v
  [ -f "$file" ] || { echo "error: $file not found" >&2; return 1; }
  v=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "$file" | head -1)
  [ -n "$v" ] || { echo "error: no [workspace.package] version in $file" >&2; return 1; }
  printf '%s\n' "$v"
}

py_version() {
  local v=${1-} re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$'
  if ! [[ "$v" =~ $re ]]; then echo "error: '$v' is not X.Y.Z or X.Y.Z-(alpha|beta|rc).N" >&2; return 1; fi
  local core=${v%%-*} pre=""
  case "$v" in
    *-alpha.*) pre="a${v##*.}" ;;
    *-beta.*)  pre="b${v##*.}" ;;
    *-rc.*)    pre="rc${v##*.}" ;;
  esac
  printf '%s%s\n' "$core" "$pre"
}
