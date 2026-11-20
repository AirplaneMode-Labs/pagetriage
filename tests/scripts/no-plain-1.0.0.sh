#!/usr/bin/env bash
# TD-107 (Sprint 7): nothing in this repository reads a plain "1.0.0" version before the owner's tag commit. The release
# candidate is 1.0.0-rc.1 (wheel 1.0.0rc1). Checked: every text file, every file name under dist/ and dist-release/, the
# release manifests, the demo (site/) and the four workspace crates in Cargo.lock. Allowed: prose about the future tag in
# CHANGELOG.md, docs/release.md, docs/RELEASING.md and docs/writeup-1.0-draft.md, and this file; third-party crates called 1.0.0 in a lock
# file or a NOTICE; the vendored release vectors under tests/vectors/ (runtime's synthetic example manifests, hash-pinned).
#
# The check is active while docs/release.md still holds the sentence "Tagging v1.0.0 today would not be honest" (TD-107,
# docs/release.md); the owner's tag commit that bumps the version also removes that sentence, which switches this test to
# "skipped: tag commit". NO_PLAIN_ROOT scans another tree (the planted-file cases below use scratch copies).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROOT_DEFAULT=${NO_PLAIN_ROOT:-$REPO}
MARKER='Tagging v1.0.0 today would not be honest'

# strip every release-candidate spelling, then look for a standalone 1.0.0 (optionally with a leading v)
strip_rc() { sed -E -e 's/1\.0\.0(-rc\.[0-9]+|rc[0-9]+)//g' -e 's/no-plain-1\.0\.0\.sh//g'; }
STANDALONE='(^|[^0-9A-Za-z.])v?1\.0\.0($|\.($|[^0-9])|[^0-9A-Za-z.])'
NAMEPLAIN='(^|[-_])1\.0\.0($|[-_.])'

# scan <root>: prints one line per finding; exit status is the number of findings (capped at 255). Written for bash 3.2 (macOS):
# no nested process substitution, the lists go through temp files.
scan() {
  local root=$1 n=0 f rel line tmp
  [ -f "$root/docs/release.md" ] && grep -qF "$MARKER" "$root/docs/release.md" || { echo "skipped: tag commit (docs/release.md no longer says '$MARKER')"; return 0; }
  tmp=$(mktemp -d)
  # 1. the workspace version
  local v
  v=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" 2>/dev/null | head -1)
  if ! [[ "$v" =~ ^1\.0\.0-rc\.[0-9]+$ ]]; then echo "Cargo.toml: workspace version is '$v', want 1.0.0-rc.N"; n=$((n+1)); fi
  # 2. the four workspace crates in the root Cargo.lock
  if [ -f "$root/Cargo.lock" ]; then
    awk '/^name = "pagetriage-(core|cli|py|wasm)"$/{nm=$0; getline; if ($0 == "version = \"1.0.0\"") print "Cargo.lock: " nm " is at 1.0.0"}' "$root/Cargo.lock" > "$tmp/lock"
    n=$((n + $(wc -l < "$tmp/lock" | tr -d ' '))); cat "$tmp/lock"
  fi
  # 3. text files (binary files are skipped by grep -I; third-party lock files and NOTICE files carry other crates' versions)
  # In a git checkout: the files git knows (tracked, or untracked and not ignored), so a venv or a build tree that .gitignore hides is never
  # scanned. Elsewhere (the planted scratch trees, a copy without .git): every file outside the usual build and venv directories.
  if [ -d "$root/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$root" ls-files -z --cached --others --exclude-standard 2>/dev/null | tr '\0' '\n' | while IFS= read -r rel; do [ -f "$root/$rel" ] && printf '%s\n' "$root/$rel"; done > "$tmp/files" || true
  else
    find "$root" \( -name .git -o -name target -o -name dist -o -name dist-release -o -name dist-release-report -o -name .venv -o -name tools-venv -o -name node_modules -o -name .scratch -o -name _site -o -name __pycache__ -o -path "$root/bench/data" -o -path "$root/site/pkg" \) -prune -o -type f -print > "$tmp/files" 2>/dev/null
  fi
  while IFS= read -r f; do
    rel=${f#"$root"/}
    case "$rel" in
      CHANGELOG.md|docs/release.md|docs/RELEASING.md|docs/writeup-1.0-draft.md|tests/scripts/no-plain-1.0.0.sh) continue ;;
      NOTICE|*/NOTICE|site/NOTICE.txt|*/Cargo.lock|Cargo.lock) continue ;;
      tests/vectors/*) continue ;;   # runtime's vendored synthetic vectors: their example manifests carry an example version; byte for byte, never edited here
    esac
    grep -n -I -E '1\.0\.0' "$f" 2>/dev/null | strip_rc | grep -E "$STANDALONE" | cut -c1-160 | sed "s|^|$rel: |" > "$tmp/hits" || true
    if [ -s "$tmp/hits" ]; then cat "$tmp/hits"; n=$((n + $(wc -l < "$tmp/hits" | tr -d ' '))); fi
  done < "$tmp/files"
  # 4. artefact names under dist/ and dist-release/, and the manifests there
  for d in dist dist-release dist-release-report; do
    [ -d "$root/$d" ] || continue
    find "$root/$d" -maxdepth 3 \( -name node_modules -o -name wasm -o -name wasm-pdf -o -name package \) -prune -o -type f -print > "$tmp/dfiles" 2>/dev/null
    while IFS= read -r f; do
      rel=${f#"$root"/}
      if printf '%s\n' "$(basename "$f")" | strip_rc | grep -qE "$NAMEPLAIN"; then echo "$rel: file name reads a plain 1.0.0"; n=$((n+1)); fi
      case "$(basename "$f")" in
        *.json)
          if grep -I -E '"version"[[:space:]]*:[[:space:]]*"1\.0\.0"' "$f" >/dev/null 2>&1; then echo "$rel: manifest version reads a plain 1.0.0"; n=$((n+1)); fi ;;
      esac
    done < "$tmp/dfiles"
  done
  rm -rf "$tmp"
  [ "$n" -gt 255 ] && n=255
  return "$n"
}

echo "== this repository"
out=$(scan "$ROOT_DEFAULT"); rc=$?
case "$out" in skipped:*) echo "$out"; ok "check skipped on the tag commit" ;; *)
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/   /'
  expect_eq "no plain 1.0.0 version before the tag (findings: $rc)" 0 "$rc" ;;
esac

echo "== planted cases (scratch copies, never the repository)"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
new_tree() { # new_tree <name>: a clean synthetic tree
  local t=$S/$1; rm -rf "$t"; mkdir -p "$t/docs" "$t/site" "$t/dist/npm" "$t/dist-release"
  printf '[workspace.package]\nversion = "1.0.0-rc.1"\n' > "$t/Cargo.toml"
  printf '[[package]]\nname = "pagetriage-core"\nversion = "1.0.0-rc.1"\n\n[[package]]\nname = "serde"\nversion = "1.0.0"\n' > "$t/Cargo.lock"
  printf 'Tagging v1.0.0 today would not be honest.\n' > "$t/docs/release.md"
  printf 'Version 1.0.0-rc.1, untagged. Wheel 1.0.0rc1.\n' > "$t/README.md"
  printf 'Release 1.0.0 is for later.\n' > "$t/CHANGELOG.md"
  printf '<p>pagetriage 1.0.0-rc.1</p>\n' > "$t/site/index.html"
  : > "$t/dist/npm/airplanemode-pagetriage-1.0.0-rc.1.tgz"
  : > "$t/dist-release/pagetriage-1.0.0rc1-cp39-abi3-macosx_11_0_arm64.whl"
  printf '{"version": "1.0.0-rc.1"}\n' > "$t/dist-release/release-manifest.json"
  echo "$t"
}
check() { # check <name> <want findings> <root>
  local out rc; out=$(scan "$3"); rc=$?
  if [ "$rc" = "$2" ]; then ok "$1"; else fail "$1 (want $2 findings, got $rc)"; printf '%s\n' "$out" | sed 's/^/   /'; fi
}
t=$(new_tree clean);                                                    check "a clean tree has no finding" 0 "$t"
t=$(new_tree readme);   printf 'Version 1.0.0 is out.\n' >> "$t/README.md"; check "README prose reading 1.0.0" 1 "$t"
t=$(new_tree readme-v); printf 'see v1.0.0.\n' >> "$t/README.md";        check "README prose reading v1.0.0." 1 "$t"
t=$(new_tree readme-ok); printf 'rc 1.0.0-rc.12 and 1.0.0rc3 and 11.0.0 and 1.0.01 and 1.0.0.1\n' >> "$t/README.md"; check "rc spellings, 11.0.0, 1.0.01 and 1.0.0.1 are not 1.0.0" 0 "$t"
t=$(new_tree site);     printf 'v1.0.0\n' >> "$t/site/index.html";        check "a demo label reading v1.0.0" 1 "$t"
t=$(new_tree wf);       mkdir -p "$t/.github/workflows"; printf 'name: "pagetriage 1.0.0"\n' > "$t/.github/workflows/x.yml"; check "a workflow reading 1.0.0" 1 "$t"
t=$(new_tree tgz);      : > "$t/dist/npm/airplanemode-pagetriage-1.0.0.tgz"; check "an npm tarball named 1.0.0" 1 "$t"
t=$(new_tree whl);      : > "$t/dist-release/pagetriage-1.0.0-cp39-abi3-macosx_11_0_arm64.whl"; check "a wheel named 1.0.0" 1 "$t"
t=$(new_tree crate);    : > "$t/dist-release/pagetriage-core-1.0.0.crate"; check "a crate named 1.0.0" 1 "$t"
t=$(new_tree man);      printf '{"version": "1.0.0"}\n' > "$t/dist-release/release-manifest.json"; check "a manifest at version 1.0.0" 1 "$t"
t=$(new_tree ver);      printf '[workspace.package]\nversion = "1.0.0"\n' > "$t/Cargo.toml"; check "Cargo.toml at 1.0.0 is a finding as a version and as text" 2 "$t"
t=$(new_tree lock);     printf '[[package]]\nname = "pagetriage-cli"\nversion = "1.0.0"\n' > "$t/Cargo.lock"; check "a workspace crate at 1.0.0 in Cargo.lock" 1 "$t"
t=$(new_tree nover);    printf '[workspace.package]\nversion = "0.1.0"\n' > "$t/Cargo.toml"; check "a workspace version that is not 1.0.0-rc.N" 1 "$t"
t=$(new_tree allow);    printf '1.0.0\n' > "$t/docs/RELEASING.md"; printf 'x 1.0.0\n' > "$t/NOTICE"; printf 'v1.0.0\n' > "$t/docs/writeup-1.0-draft.md"; check "allowlisted prose, a NOTICE and the third-party crate in Cargo.lock" 0 "$t"
t=$(new_tree tag);      printf '[workspace.package]\nversion = "1.0.0"\n' > "$t/Cargo.toml"; printf 'The release is out.\n' > "$t/docs/release.md"; printf 'Version 1.0.0\n' > "$t/README.md"; out=$(scan "$t"); rc=$?
expect_eq "on the tag commit (marker sentence removed) the check is skipped" "0:skipped" "$rc:$(printf '%s' "$out" | cut -c1-7)"
finish
