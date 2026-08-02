#!/usr/bin/env bash
# Unit tests for the community-health file set (issue #66, M5):
# .github/CONTRIBUTING.md, .github/CODE_OF_CONDUCT.md,
# .github/ISSUE_TEMPLATE/{bug_report,feature_request}.md, and
# .github/pull_request_template.md.
# Run directly: tests/unit/community-health.test.sh
#
# Pins the AC-mandated invariants so a later edit can't silently drop them: the
# five files exist, CONTRIBUTING carries each required topic IN THE SECTION THAT
# OWNS IT, the agent pipeline names all three agents in order, the issue and PR
# templates carry their required fields, and the Code of Conduct has no
# unfilled adopter placeholders left.
#
# Every content assertion is SECTION-SCOPED, never a whole-file grep: these are
# prose documents where the same vocabulary recurs in intros, links, and
# cross-references, so a whole-file `grep -qF` stays green even when the section
# it claims to pin is gutted. `section` extracts the body BETWEEN a heading and
# the next heading of the same or higher level and DROPS THE HEADING LINE
# itself, so a heading that restates its own topic word can never satisfy a
# check meant to pin the body.
#
# Style mirrors tests/unit/docs-set.test.sh: raw bash, `set -u`, PASS/FAIL
# counters, non-zero exit on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# section <file> <exact heading line>
# Prints the section body: every line after the heading, up to (not including)
# the next heading at the same or a higher level. The heading line itself is
# never printed.
section() {
  local file="$1" heading="$2"
  awk -v want="$heading" '
    function hashes(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    !started && $0 == want { started = 1; level = hashes($0); next }
    started && /^#+[ \t]/ { if (hashes($0) <= level) exit }
    started { print }
  ' "$REPO_ROOT/$file"
}

# assert_in_section <file> <heading> <desc> <literal>
assert_in_section() {
  local file="$1" heading="$2" desc="$3" needle="$4"
  if section "$file" "$heading" | grep -qF -- "$needle"; then
    ok "$desc"
  else
    no "$desc"
  fi
}

# assert_absent <file> <desc> <extended-regex>
assert_absent() {
  local file="$1" desc="$2" pattern="$3"
  if grep -qE -- "$pattern" "$REPO_ROOT/$file" 2>/dev/null; then
    no "$desc"
  else
    ok "$desc"
  fi
}

CONTRIB=.github/CONTRIBUTING.md
COC=.github/CODE_OF_CONDUCT.md
BUG=.github/ISSUE_TEMPLATE/bug_report.md
FEAT=.github/ISSUE_TEMPLATE/feature_request.md
PRT=.github/pull_request_template.md

echo "community-health.test.sh — the issue #66 community-health file set"

# --- the five files exist ----------------------------------------------------
for f in "$CONTRIB" "$COC" "$BUG" "$FEAT" "$PRT"; do
  if [ -f "$REPO_ROOT/$f" ]; then
    ok "$f exists"
  else
    no "$f exists"
  fi
done

# --- the `section` helper itself discriminates -------------------------------
# A scoping helper that silently returned the whole file would make every
# assertion below vacuous, so prove it excludes a sibling section AND the
# heading line. "Sherlock Holmes" lives only in the pipeline section.
if section "$CONTRIB" "### Commit format" | grep -qF "Sherlock Holmes"; then
  no "section() excludes sibling sections"
else
  ok "section() excludes sibling sections"
fi
if section "$CONTRIB" "## Filing an issue" | grep -qF "## Filing an issue"; then
  no "section() drops the heading line"
else
  ok "section() drops the heading line"
fi
if [ -n "$(section "$CONTRIB" "### Commit format")" ]; then
  ok "section() returns a non-empty body for a real heading"
else
  no "section() returns a non-empty body for a real heading"
fi

# --- AC 1: CONTRIBUTING covers each required topic, in its owning section -----
assert_in_section "$CONTRIB" "## Filing an issue" \
  "CONTRIBUTING tells contributors to use the bug template" "ISSUE_TEMPLATE/bug_report.md"
assert_in_section "$CONTRIB" "## Filing an issue" \
  "CONTRIBUTING tells contributors to use the feature template" "ISSUE_TEMPLATE/feature_request.md"
assert_in_section "$CONTRIB" "### Commit format" \
  "CONTRIBUTING requires Conventional Commits + Gitmoji" "Conventional Commits + Gitmoji"
assert_in_section "$CONTRIB" "### Commit format" \
  "CONTRIBUTING requires atomic commits" "atomic"
assert_in_section "$CONTRIB" "### Tests" \
  "CONTRIBUTING states the every-change-gets-a-test rule" "Every change gets a test"
assert_in_section "$CONTRIB" "### Tests" \
  "CONTRIBUTING gives the test-suite command" "scripts/test.sh"
assert_in_section "$CONTRIB" "### Tests" \
  "CONTRIBUTING points at the canonical test harness doc" "docs/testing.md"
assert_in_section "$CONTRIB" "## Read this first" \
  "CONTRIBUTING states the no-secrets rule" "Never commit a secret"
assert_in_section "$CONTRIB" "## Read this first" \
  "CONTRIBUTING names the secret scanner that enforces it" "bin/secret-scan.sh"

# --- AC 2: the agent pipeline, all three agents, plus the human-merge gate ----
PIPE="## How your issue moves through the agent pipeline"
assert_in_section "$CONTRIB" "$PIPE" \
  "pipeline names Inspector Lestrade (triage)" "Inspector Lestrade"
assert_in_section "$CONTRIB" "$PIPE" \
  "pipeline names Dr. Watson (development)" "Dr. Watson"
assert_in_section "$CONTRIB" "$PIPE" \
  "pipeline names Sherlock Holmes (review)" "Sherlock Holmes"
assert_in_section "$CONTRIB" "$PIPE" \
  "pipeline explains acceptance-criteria refinement" "acceptance criteria"
assert_in_section "$CONTRIB" "$PIPE" \
  "pipeline states no agent merges — a human does" "A human merges"
assert_in_section "$CONTRIB" "$PIPE" \
  "pipeline describes the human-submitted PR path" "If you submit a pull request yourself"
# Order matters: triage → development → review. Pin the sequence, not just
# co-presence, so a reordering that misdescribes the pipeline fails.
PIPE_ORDER="$(section "$CONTRIB" "$PIPE" \
  | grep -oE 'Inspector Lestrade|Dr\. Watson|Sherlock Holmes' | head -3 | tr '\n' ',')"
if [ "$PIPE_ORDER" = "Inspector Lestrade,Dr. Watson,Sherlock Holmes," ]; then
  ok "pipeline lists the three agents in triage → development → review order"
else
  no "pipeline lists the three agents in order (got: $PIPE_ORDER)"
fi

# --- AC 3: the not-tax-advice and security/privacy postures ------------------
assert_in_section "$CONTRIB" "## Read this first" \
  "CONTRIBUTING states the not-tax-advice posture" "not tax advice"
assert_in_section "$CONTRIB" "## Read this first" \
  "CONTRIBUTING points at the canonical disclaimer wording" "skills/shared/disclaimer.md"
assert_in_section "$CONTRIB" "## Read this first" \
  "CONTRIBUTING points at the security posture" "SECURITY.md"
assert_in_section "$CONTRIB" "## Read this first" \
  "CONTRIBUTING states the Keychain-only token rule" "only** in the macOS Keychain"
assert_in_section "$CONTRIB" "## Read this first" \
  "CONTRIBUTING states the owner-only artifact rule" "0600"

# --- AC 4: concise — points at conventions rather than re-deriving them -------
# A bound, not a style opinion: the AC's failure mode is CONTRIBUTING growing
# into a second copy of docs/testing.md + SECURITY.md. The current file is well
# under this; crossing it means the doc started re-deriving instead of linking.
CONTRIB_LINES="$(wc -l < "$REPO_ROOT/$CONTRIB")"
if [ "$CONTRIB_LINES" -le 200 ]; then
  ok "CONTRIBUTING is concise ($CONTRIB_LINES lines, bound 200)"
else
  no "CONTRIBUTING is concise ($CONTRIB_LINES lines exceeds the 200-line bound)"
fi

# --- AC 5/6: issue templates — frontmatter and the fields that make a report
# actionable ------------------------------------------------------------------
for tmpl in "$BUG" "$FEAT"; do
  if [ "$(head -1 "$REPO_ROOT/$tmpl")" = "---" ]; then
    ok "$tmpl opens with YAML frontmatter"
  else
    no "$tmpl opens with YAML frontmatter"
  fi
done
assert_in_section "$BUG" "## Steps to reproduce" \
  "bug template numbers the reproduction steps" "1."
assert_in_section "$BUG" "## Environment" \
  "bug template asks for the plugin version" "Plugin version"
assert_in_section "$BUG" "## Environment" \
  "bug template asks for the Claude Code version" "Claude Code version"
for h in "## Expected behaviour" "## Actual behaviour"; do
  if [ -n "$(section "$BUG" "$h")" ]; then
    ok "bug template has a non-empty \"${h#\#\# }\" section"
  else
    no "bug template has a non-empty \"${h#\#\# }\" section"
  fi
done
# Both templates must warn against pasting real financial data — this tracker is
# public and the plugin's whole subject matter is a live budget.
for tmpl in "$BUG" "$FEAT"; do
  if grep -qF "Never paste real financial data" "$REPO_ROOT/$tmpl"; then
    ok "$tmpl warns against pasting real financial data"
  else
    no "$tmpl warns against pasting real financial data"
  fi
done
if grep -qF "labels: bug" "$REPO_ROOT/$BUG"; then
  ok "bug template auto-labels bug"
else
  no "bug template auto-labels bug"
fi
if grep -qF "labels: enhancement" "$REPO_ROOT/$FEAT"; then
  ok "feature template auto-labels enhancement"
else
  no "feature template auto-labels enhancement"
fi
assert_in_section "$FEAT" "## The problem" \
  "feature template asks for the problem, not the solution" "not the solution"

# --- AC 7: PR template checklist ---------------------------------------------
assert_in_section "$PRT" "## Checklist" \
  "PR checklist requires tests added" "Tests added"
assert_in_section "$PRT" "## Checklist" \
  "PR checklist requires no secrets committed" "No secrets committed"
assert_in_section "$PRT" "## Checklist" \
  "PR checklist requires Conventional Commits + Gitmoji" "Conventional Commits + Gitmoji"
assert_in_section "$PRT" "## Checklist" \
  "PR checklist requires a linked issue number" "Linked issue number present"
assert_in_section "$PRT" "## Linked issue" \
  "PR template carries the Fixes keyword that closes the issue on merge" "Fixes #"

# --- AC 8: Code of Conduct — canonical text, no adopter placeholders left -----
assert_in_section "$COC" "# Contributor Covenant 3.0 Code of Conduct" \
  "CODE_OF_CONDUCT links its canonical upstream version" \
  "https://www.contributor-covenant.org/version/3/0/"
# The two `**[NOTE: …]**` markers upstream ships are instructions to the
# ADOPTER, not policy. Publishing either one would make the document tell the
# reader to go edit it. This assertion is what caught them unfilled.
assert_absent "$COC" "CODE_OF_CONDUCT has no unfilled adopter placeholders" '\*\*\[NOTE:'
assert_in_section "$COC" "## Reporting an Issue" \
  "CODE_OF_CONDUCT names the maintainer as the reporting contact" "@mike-bronner"
assert_in_section "$COC" "## Reporting an Issue" \
  "CODE_OF_CONDUCT forbids reporting a violation in a public issue" \
  "Do not open a public issue to report a"
assert_in_section "$COC" "## Addressing and Repairing Harm" \
  "CODE_OF_CONDUCT adopts the upstream remedies as its own policy" \
  "adopts the remedies and repairs below, as written"

# --- CONTRIBUTING links the Code of Conduct ----------------------------------
assert_in_section "$CONTRIB" "## Code of Conduct" \
  "CONTRIBUTING links the Code of Conduct" "(CODE_OF_CONDUCT.md)"

# --- every relative link in the set resolves ---------------------------------
# CI's lychee gate (.github/workflows/ci.yml, `docs-links`) scans only
# 'assets/**/*.md', 'docs/**/*.md', and 'README.md' — it does NOT cover
# .github/, so nothing else catches a broken relative link in these five files.
# The failure mode is real and depth-sensitive: files under
# .github/ISSUE_TEMPLATE/ need '../../' to reach the repo root while their
# siblings one level up need '../', so a link copied between the two breaks
# silently. Fragments are stripped; absolute URLs are out of scope (offline).
BROKEN=0
for f in "$CONTRIB" "$COC" "$BUG" "$FEAT" "$PRT"; do
  dir="$(dirname "$REPO_ROOT/$f")"
  while read -r link; do
    [ -n "$link" ] || continue
    target="${link%%#*}"
    [ -n "$target" ] || continue
    if [ ! -e "$dir/$target" ]; then
      no "$f link resolves: $link"
      BROKEN=$((BROKEN + 1))
    fi
  done < <(grep -oE '\]\([^)#][^)]*\)' "$REPO_ROOT/$f" \
             | sed -E 's/^\]\(|\)$//g' | grep -v '^https\?://' | sort -u)
done
if [ "$BROKEN" -eq 0 ]; then
  ok "every relative link in the community-health set resolves"
fi

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
