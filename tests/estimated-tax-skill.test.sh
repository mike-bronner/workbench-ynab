#!/usr/bin/env bash
#
# estimated-tax-skill.test.sh — verifies the estimated-tax skill's failure-report
# instruction closes the agent-facing disclosure surface (issue #235).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/estimated-tax-skill.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/review-skill.test.sh: raw bash, `set -u`, PASS/FAIL counters, a non-zero
# exit when anything fails. Auto-discovered by scripts/test.sh.
#
# Why a structural string check: the disclosure surface here is an INSTRUCTION,
# not code. `loadProfile()`'s `error.errors[]` is deliberately raw for
# programmatic callers (#225 AC #3) — each entry's `path` / `message` /
# `params.additionalProperty` / `params.propertyName` embeds the offending JSON
# property name verbatim, and a key at the profile root or under the schema-open
# `overrides` layer can carry secret-shaped bytes. The skill-following agent is
# itself a direct caller, so the only thing standing between that raw array and
# human-facing chat/report output is the wording of step 1. These assertions are
# the regression guard on that wording. The complementary guard — that
# `errors[]` STAYS raw for programmatic callers — lives in
# tests/unit/load-profile.test.mjs (#225), and this file deliberately asserts
# nothing about lib/tax/loadProfile.mjs.
#
# Assertions run against a NORMALIZED rendering of the file: blockquote markers
# stripped, all whitespace runs collapsed to one space. Prose reflow and moving a
# rule into or out of a `>` callout are editorial, not behavioral, so they must
# not break the guard — only the words themselves may.

# shellcheck disable=SC2016
# ^ Needles are single-quoted on purpose: many contain markdown backticks (e.g.
# '`error.kind`') and must reach grep byte-for-byte, with no command
# substitution. Same rationale as the per-line disable in review-skill.test.sh,
# hoisted to file scope because most assertions below carry a backtick.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/estimated-tax/SKILL.md"
COMMAND="${REPO_ROOT}/commands/ynab-tax.md"

pass=0
fail=0
NORM=""    # normalized text of the file under assertion
LABEL=""   # its short name, for failure output

# set_target <file> <label> — normalize <file> and point the assertions at it.
set_target() {
  LABEL="$2"
  NORM="$(sed 's/^[[:space:]]*>[[:space:]]\{0,1\}//' "$1" | tr -s '[:space:]' ' ')"
}

# assert_present <desc> <needle> — the target must contain <needle> (literal).
assert_present() {
  local desc="$1" needle="$2"
  if printf '%s' "$NORM" | grep -qF -- "$needle"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — [%s] %s: %s not found\n' "$LABEL" "$desc" "$needle"; fail=$((fail + 1))
  fi
}

# assert_present_re <desc> <regex> — the target must match <regex> (ERE).
assert_present_re() {
  local desc="$1" re="$2"
  if printf '%s' "$NORM" | grep -qE -- "$re"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — [%s] %s: /%s/ did not match\n' "$LABEL" "$desc" "$re"; fail=$((fail + 1))
  fi
}

# assert_absent_re <desc> <regex> — the target must NOT match <regex> (ERE).
assert_absent_re() {
  local desc="$1" re="$2"
  if printf '%s' "$NORM" | grep -qE -- "$re"; then
    printf 'FAIL — [%s] %s: /%s/ unexpectedly matched\n' "$LABEL" "$desc" "$re"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

# ---- both instruction files exist --------------------------------------------
for f in "$SKILL" "$COMMAND"; do
  if [ ! -f "$f" ]; then
    printf 'FAIL — instruction file missing at %s\n' "$f"
    printf '\n%d passed, %d failed\n' "$pass" $((fail + 1))
    exit 1
  fi
done
printf 'ok   — skill exists at skills/estimated-tax/SKILL.md\n'; pass=$((pass + 1))
printf 'ok   — command exists at commands/ynab-tax.md\n';        pass=$((pass + 1))

set_target "$SKILL" "SKILL.md"

# ---- step 1 still STOPS the run on ok:false (AC 3) ---------------------------
# Only *what may be surfaced* changes; the stop-on-failure behavior is untouched.
assert_present_re "step 1 keys on loadProfile() returning ok: false" 'ok: ?false'
assert_present_re "step 1 stops the run on failure"                  '[Ss]top the run'
assert_present    "keeps the silently-wrong-number rationale"        "silently-wrong"

# ---- the human-facing surface is an ALLOW-LIST of exactly kind + message (AC 1)
# Naming the permitted fields — rather than only banning a dump — is what leaves
# a "summarize what's wrong" paraphrase no foothold (AC 6).
assert_present    "surface is an exclusive allow-list"       "only these two"
assert_present    "allows error.kind"                        '`error.kind`'
assert_present    "allows error.message"                     '`error.message`'
assert_present_re "calls those two the human-safe fields"    'human-safe|redacted'
assert_present    "no other field of error may be emitted"   'no other field of `error`'

# ---- the raw errors[] array is off-limits for human output (AC 2) ------------
assert_present    "explicit never-surface rule for errors[]" 'Never surface `error.errors[]`'
assert_present_re "bans quoting AND paraphrasing AND summarizing" \
  'quote.*paraphrase.*summarize'
assert_present_re "the ban covers chat and report output" 'in chat.*in the report|in the report.*in chat'
# It must name the specific carriers of the offending property name, so the agent
# cannot decide some sub-field is "safe enough" to mention.
assert_present    "names errors[].path as off-limits"   '`path`'
assert_present    "names errors[].params as off-limits" '`params`'
assert_present    "names params.additionalProperty"     '`additionalProperty`'
assert_present    "names params.propertyName"           '`propertyName`'
# The direct-question path is the paraphrase loophole (AC 6) — close it by name.
assert_present_re "closes the 'which property is wrong?' question path" \
  'even when the human asks outright'
# States WHY, so the rule survives an agent that reasons about intent.
assert_present_re "explains the secret-shaped-key threat" 'secret-shaped'
assert_present_re "explains errors[] is intentionally raw for programmatic callers" \
  'intentionally.*raw|raw.*for programmatic callers'

# ---- the old permissive wording is gone (AC 2/5) -----------------------------
# "surface the structured error" was the pre-#235 instruction: it authorized the
# whole envelope, errors[] included.
assert_absent_re "no permissive 'surface the structured error' instruction" \
  'surface the structured error'
# No instruction may reach into an individual violation.
assert_absent_re "never reaches into errors[0]" 'errors\[0\]'

# ---- the loader itself is NOT touched by this issue (AC 4) -------------------
# errors[] stays fully unredacted for direct/programmatic callers; the skill must
# not ask for a code-side change or claim one happened.
assert_absent_re "skill does not claim errors[] is redacted" \
  'errors\[\] (is|are) (now )?redacted'

# ---- the invoking command's summary matches the skill (doc-drift) ------------
# commands/ynab-tax.md paraphrases step 1 for the user; its old summary ("stops
# with the structured error") authorized exactly what the skill now forbids.
set_target "$COMMAND" "ynab-tax.md"
assert_absent_re "command carries no 'structured error' authorization" \
  'stops with the structured error'
assert_present_re "command names the redacted kind + message surface" \
  '`error\.kind`.*`error\.message`'
assert_present_re "command repeats the never-surface-errors[] rule" \
  'never surface the raw `error\.errors\[\]`'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
