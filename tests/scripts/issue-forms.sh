#!/usr/bin/env bash
# TD-117 (Sprint 7): the issue forms. A bug form with a REQUIRED checkbox that says no real document is attached, a feature form,
# and a config that turns blank issues off and points vulnerability reports at SECURITY.md (private reporting is an owner step:
# enabling it is a repository setting). Also CONTRIBUTING.md and the security contact. Plain-text checks only (no YAML library
# is assumed); ISSUE_ROOT overrides the tree under test (the planted cases use scratch copies).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROOT=${ISSUE_ROOT:-$REPO}
BOX='I have not attached any real, confidential or personal document (bank, legal, medical, identity). Any sample is synthetic or public.'

# check_tree <root>: prints one line per problem
check_tree() {
  local r=$1 d=$1/.github/ISSUE_TEMPLATE
  for f in bug_report.yml feature_request.yml config.yml; do [ -f "$d/$f" ] || echo "missing .github/ISSUE_TEMPLATE/$f"; done
  [ -f "$r/CONTRIBUTING.md" ] || echo "missing CONTRIBUTING.md"
  [ -f "$r/SECURITY.md" ] || echo "missing SECURITY.md"
  if [ -f "$d/config.yml" ]; then
    grep -qxE 'blank_issues_enabled:[[:space:]]*false' "$d/config.yml" || echo "config.yml: blank_issues_enabled is not false"
    grep -qE 'url:[[:space:]]*https://github\.com/AirplaneMode-Labs/pagetriage/blob/main/SECURITY\.md[[:space:]]*$' "$d/config.yml" || echo "config.yml: no contact link to SECURITY.md"
    grep -qE '^contact_links:' "$d/config.yml" || echo "config.yml: no contact_links"
  fi
  for f in bug_report.yml feature_request.yml; do
    [ -f "$d/$f" ] || continue
    grep -qE '^name: .+' "$d/$f" || echo "$f: no name"
    grep -qE '^description: .+' "$d/$f" || echo "$f: no description"
    grep -qE '^body:' "$d/$f" || echo "$f: no body"
  done
  if [ -f "$d/bug_report.yml" ]; then
    # the checkbox: its label is the exact sentence, and the option is required
    if ! awk -v box="$BOX" '
        /^[[:space:]]*- type: checkboxes/ {inbox=1}
        inbox && index($0, "label: \"" box "\"") {seen=1; getline; if ($0 ~ /^[[:space:]]*required: true[[:space:]]*$/) req=1}
        END {exit !(seen && req)}' "$d/bug_report.yml"; then echo "bug_report.yml: no required checkbox with the exact no-real-documents sentence"; fi
    grep -qi 'redact' "$d/bug_report.yml" || echo "bug_report.yml: no line asking for redaction"
    grep -qE 'SECURITY\.md' "$d/bug_report.yml" || echo "bug_report.yml: no pointer to SECURITY.md for vulnerabilities"
    grep -qE 'attach' "$d/bug_report.yml" || echo "bug_report.yml: nothing about attachments"
  fi
  if [ -f "$d/feature_request.yml" ]; then grep -qE 'SECURITY\.md|vulnerab' "$d/feature_request.yml" || echo "feature_request.yml: no pointer for vulnerabilities"; fi
  if [ -f "$r/SECURITY.md" ]; then grep -qiE 'do not open a public issue|never in a public issue|not .* public issue' "$r/SECURITY.md" || echo "SECURITY.md: does not say to report privately, never in a public issue"; fi
  if [ -f "$r/CONTRIBUTING.md" ]; then grep -qiE 'real document|synthetic' "$r/CONTRIBUTING.md" || echo "CONTRIBUTING.md: nothing about real documents"; fi
  return 0
}

echo "== this repository"
P=$(check_tree "$ROOT")
if [ -z "$P" ]; then ok "bug_report.yml, feature_request.yml, config.yml, CONTRIBUTING.md and SECURITY.md are in order"; else fail "issue forms and contributor files"; printf '%s\n' "$P" | sed 's/^/   /'; fi

echo "== planted problems (scratch copies)"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
copy_tree() { local t=$S/$1; rm -rf "$t"; mkdir -p "$t/.github"; cp -R "$ROOT/.github/ISSUE_TEMPLATE" "$t/.github/" 2>/dev/null; cp "$ROOT/CONTRIBUTING.md" "$ROOT/SECURITY.md" "$t/" 2>/dev/null; echo "$t"; }
count_problems() { check_tree "$1" | grep -c .; }
t=$(copy_tree ok);        expect_eq "an intact copy has no problem" 0 "$(count_problems "$t")"
t=$(copy_tree nobox);     sed -i.bak 's/required: true/required: false/' "$t/.github/ISSUE_TEMPLATE/bug_report.yml"; rm -f "$t/.github/ISSUE_TEMPLATE/bug_report.yml.bak"
expect_eq "a checkbox that is not required is refused" 1 "$([ "$(count_problems "$t")" -ge 1 ] && echo 1 || echo 0)"
t=$(copy_tree reword);    sed -i.bak 's/not attached any real/not attached any/' "$t/.github/ISSUE_TEMPLATE/bug_report.yml"; rm -f "$t/.github/ISSUE_TEMPLATE/bug_report.yml.bak"
expect_eq "a reworded checkbox sentence is refused" 1 "$([ "$(count_problems "$t")" -ge 1 ] && echo 1 || echo 0)"
t=$(copy_tree blank);     sed -i.bak 's/blank_issues_enabled: false/blank_issues_enabled: true/' "$t/.github/ISSUE_TEMPLATE/config.yml"; rm -f "$t/.github/ISSUE_TEMPLATE/config.yml.bak"
expect_eq "blank issues enabled is refused" 1 "$([ "$(count_problems "$t")" -ge 1 ] && echo 1 || echo 0)"
t=$(copy_tree nolink);    sed -i.bak 's#SECURITY\.md#README.md#' "$t/.github/ISSUE_TEMPLATE/config.yml"; rm -f "$t/.github/ISSUE_TEMPLATE/config.yml.bak"
expect_eq "a contact link that does not point at SECURITY.md is refused" 1 "$([ "$(count_problems "$t")" -ge 1 ] && echo 1 || echo 0)"
t=$(copy_tree nofeat);    rm -f "$t/.github/ISSUE_TEMPLATE/feature_request.yml"
expect_eq "a missing feature form is refused" 1 "$([ "$(count_problems "$t")" -ge 1 ] && echo 1 || echo 0)"
finish
