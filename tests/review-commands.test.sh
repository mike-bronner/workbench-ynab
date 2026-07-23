#!/usr/bin/env bash
#
# review-commands.test.sh — verifies the /ynab-review router command and the
# four ad-hoc tier commands (issue #45).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/review-commands.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/review-wrappers.test.sh: raw bash, `set -u`, PASS/FAIL counters, a
# non-zero exit when anything fails. Auto-discovered by scripts/test.sh.
#
# The commands are static markdown assets, so the assertions are structural
# string checks — the regression guard for the contract in issue #45: the
# router has three phases (Plan / Surface / Execute), pre-warms the YNAB MCP
# best-effort, dispatches the orchestrator exactly once, surfaces warnings via
# a single batched AskUserQuestion, marks chapters at phase transitions, and
# executes the tier wrappers; each ad-hoc command forces its own single tier
# while retaining the plan's window + warnings. All five files stay in the
# namespaced-tool world with ZERO duplicated methodology and ZERO hardcoded
# concrete tool names (the swap-ready invariant, issue #87).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMANDS_DIR="${REPO_ROOT}/commands"

pass=0
fail=0
FILE=""  # the command file currently under test (set per-section below)

# assert_present <desc> <needle> — the file must contain <needle> (literal).
assert_present() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$FILE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found in %s\n' "$desc" "$needle" "${FILE##*/}"; fail=$((fail + 1))
  fi
}

# assert_present_re <desc> <regex> — the file must match <regex> (ERE, case-insensitive).
assert_present_re() {
  local desc="$1" re="$2"
  if grep -qiE -- "$re" "$FILE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match in %s\n' "$desc" "$re" "${FILE##*/}"; fail=$((fail + 1))
  fi
}

# assert_absent_re <desc> <regex> — the file must NOT match <regex> (ERE).
assert_absent_re() {
  local desc="$1" re="$2"
  if grep -qE -- "$re" "$FILE"; then
    printf 'FAIL — %s: /%s/ unexpectedly matched in %s\n' "$desc" "$re" "${FILE##*/}"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

# assert_present_flat_re <desc> <regex> — like assert_present_re, but newlines
# are flattened to spaces first, so prose assertions survive markdown
# line-wrapping (grep is line-based; wrapped sentences would never match).
assert_present_flat_re() {
  local desc="$1" re="$2"
  if tr '\n' ' ' < "$FILE" | grep -qiE -- "$re"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match (flattened) in %s\n' "$desc" "$re" "${FILE##*/}"; fail=$((fail + 1))
  fi
}

# assert_absent_flat_re <desc> <regex> — like assert_absent_re, on the
# newline-flattened file, so a defect phrase can't hide across a line wrap.
assert_absent_flat_re() {
  local desc="$1" re="$2"
  if tr '\n' ' ' < "$FILE" | grep -qiE -- "$re"; then
    printf 'FAIL — %s: /%s/ unexpectedly matched (flattened) in %s\n' "$desc" "$re" "${FILE##*/}"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

# Shared invariants for all five command files (router + ad-hoc tiers).
check_shared() {
  local label="$1"

  # Namespaced tools only — the family glob is the documented derivation rule…
  assert_present "[$label] names the namespaced tool prefix" \
    'mcp__plugin_workbench-ynab_ynab__*'
  # …the legacy un-namespaced prefix must never appear…
  assert_absent_re "[$label] no un-namespaced mcp__ynab__ reference" 'mcp__ynab__'
  # …and no concrete tool name may be inlined (swap-ready invariant, issue #87).
  assert_absent_re "[$label] no hardcoded concrete tool name" \
    "mcp__plugin_workbench-ynab_ynab__ynab_[a-z_]+"

  # Names are resolved from the single source of truth.
  assert_present "[$label] resolves tool names from the protocol SSoT" \
    'skills/protocol/ynab-tools.md'

  # Pre-warm is best-effort, via ToolSearch, one discarded call, never a gate.
  assert_present "[$label] pre-warms via ToolSearch" 'ToolSearch'
  assert_present_re "[$label] pre-warm is best-effort" 'best-effort'
  assert_present_flat_re "[$label] pre-warm makes one discardable call" \
    'one[^.]*(discardable call|call and discard)'
  assert_present_re "[$label] pre-warm never gates dispatch" \
    'never gate|proceed on any (warm-up )?error'

  # Dispatches the read-only orchestrator exactly once, handing it today's
  # date and the configured timezone in the prompt.
  assert_present "[$label] dispatches the ynab-orchestrator" 'ynab-orchestrator'
  assert_present_re "[$label] dispatch carries today" 'today: <?YYYY-MM-DD'
  assert_present_re "[$label] dispatch carries the timezone" 'timezone:'

  # Timezone is the required source of truth for date math (issue #31): resolved
  # fail-closed via _cfg_timezone, and `today` derived in that zone via
  # _today_in_tz — never the host clock.
  assert_present "[$label] resolves the timezone fail-closed via _cfg_timezone" \
    '_cfg_timezone'
  assert_present "[$label] derives today in the configured tz via _today_in_tz" \
    '_today_in_tz'
  assert_absent_flat_re "[$label] no host-clock timezone fallback" \
    'fall back to the system timezone when unset'
  assert_present_re "[$label] orchestrator dispatched only once" \
    '(exactly|only) once|once per run'

  # No fabricated answers when the user doesn't respond.
  assert_present_re "[$label] never fabricates an answer" 'never fabricate|no fabricated'

  # No instruction anywhere to dump the raw warnings at the user (the negated
  # rule — "never dump raw YAML" — never phrases it this way).
  assert_absent_flat_re "[$label] never instructs dumping raw output at the user" \
    '(paste|dump|print|show|write) the raw'

  # Read-only stance reaffirmed.
  assert_present_re "[$label] reaffirms read-only" 'read-only'

  # THIN: zero duplicated methodology — none of the universal protocol's
  # machinery may live in a command.
  assert_present_re "[$label] declares no methodology lives here" \
    'no methodology lives here|belongs in the universal protocol'
  assert_absent_re "[$label] no frozen-template SLOT machinery" 'SLOT:'
  assert_absent_re "[$label] no milliunit conversion rule" 'milliunit'
  assert_absent_re "[$label] no 12-section methodology body" '12-section'
}

# ---- the /ynab-review router ---------------------------------------------------
FILE="${COMMANDS_DIR}/ynab-review.md"
if [ ! -f "$FILE" ]; then
  printf 'FAIL — router missing at commands/ynab-review.md\n'
  fail=$((fail + 1))
else
  printf 'ok   — router exists at commands/ynab-review.md\n'; pass=$((pass + 1))

  # Three-phase structure, and the router is the scheduled task's only entry point.
  assert_present_re "[router] Plan phase heading"    '^## Step 1 — Plan'
  assert_present_re "[router] Surface phase heading" '^## Step 2 — Surface'
  assert_present_re "[router] Execute phase heading" '^## Step 3 — Execute'
  assert_present_re "[router] only entry point for the scheduled task" \
    'only.{0,20}entry point'
  assert_present_re "[router] scheduled task uses this same router" \
    'scheduled task uses this same router'

  # Plan: config resolution through the shared loader, then the trailing YAML
  # plan is parsed (today/timezone in the dispatch are covered by check_shared).
  assert_present "[router] resolves config via the shared loader" 'bin/config.sh'
  assert_present_re "[router] parses the trailing YAML plan block" \
    '(last|trailing) YAML block'
  assert_present "[router] consumes plan.report.tiers" 'plan.report.tiers'
  assert_present "[router] consumes plan.warnings"     'plan.warnings'
  # Anchored to the Step 3 hand-off — the bare word "window" also appears in
  # doc prose, which must not satisfy this check.
  # shellcheck disable=SC2016
  assert_present "[router] hands each tier its window from the plan reasons" \
    'window from `plan.report.reasons.<tier>.window`'

  # Surface: silent skip when empty; translated warnings; one batched ask;
  # the answer is honored.
  assert_present_re "[router] empty warnings skip silently" \
    'proceed to Step 3 silently'
  assert_present_re "[router] warnings translated to plain English" 'plain.English'
  # Guard the actual Rule A instruction — deleting it must fail this test.
  assert_present_flat_re "[router] carries the never-dump-raw-YAML rule" \
    'Never dump .kind:.{0,20}options:.{0,20}or raw YAML'
  assert_present "[router] decisions via AskUserQuestion" 'AskUserQuestion'
  assert_present_re "[router] batches decisions into a single ask" \
    'single.{0,30}AskUserQuestion'
  assert_present_re "[router] never skips Surface when warnings exist" \
    'never skip the surface step'

  # Execute: tier wrappers from skills/review/, in plan order, via the
  # plugin-root variable — no hardcoded absolute/relative path.
  # shellcheck disable=SC2016
  assert_present "[router] executes wrappers via \${CLAUDE_PLUGIN_ROOT}" \
    '${CLAUDE_PLUGIN_ROOT}/skills/review/'
  assert_absent_re "[router] no hardcoded absolute/relative wrapper path" \
    '(/Users/|\.\./)[^ ]*skills/review/'
  for tier in weekly monthly quarterly-tax annual; do
    assert_present "[router] names the ${tier} wrapper" "${tier}-ynab-review.md"
  done
  assert_present_re "[router] runs tiers in plan order" 'plan order'

  # Chapter marks at phase transitions.
  assert_present "[router] marks chapters via ccd_session" \
    'mcp__ccd_session__mark_chapter'
  assert_present "[router] marks the Plan chapter"     'mark_chapter(title="Plan")'
  assert_present "[router] marks the Warnings chapter" 'mark_chapter(title="Warnings")'
  assert_present "[router] marks each tier chapter"    'mark_chapter(title="<tier>")'
  assert_present_re "[router] Warnings chapter only when warnings exist" \
    'only when warnings exist'

  # Hard rules.
  assert_present_re "[router] mutation is a bug" 'mutation = bug'

  check_shared "router"
fi

# ---- the four ad-hoc tier commands ---------------------------------------------
for tier in weekly monthly quarterly-tax annual; do
  FILE="${COMMANDS_DIR}/ynab-${tier}-review.md"

  if [ ! -f "$FILE" ]; then
    printf 'FAIL — ad-hoc command missing at commands/ynab-%s-review.md\n' "$tier"
    fail=$((fail + 1)); continue
  fi
  printf 'ok   — ad-hoc command exists at commands/ynab-%s-review.md\n' "$tier"; pass=$((pass + 1))

  # Forces its own single tier: authoritative ad-hoc scope in the dispatch,
  # plus the returned tiers list overridden to this tier only.
  assert_present "[$tier] dispatches with an authoritative review_scope" \
    "review_scope: ${tier}"
  assert_present "[$tier] overrides the returned tiers list" \
    "force the execution tier to"
  assert_present_re "[$tier] forces its own tier" \
    "force the execution tier to[[:space:]\`']*${tier}"
  assert_present_re "[$tier] runs only its own tier" 'do not run other tiers'

  # Retains the plan's window + warnings for its tier — anchored to the
  # "Keep everything else" override sentence, not the bare word "warnings"
  # (which the Phase 2 heading alone would satisfy).
  assert_present_re "[$tier] retains the plan window"   "${tier}[[:space:]\`']*window|window[^.]*${tier}"
  assert_present_flat_re "[$tier] retains the plan warnings" \
    "Keep everything else.{0,80}\`warnings\`"

  # Surfaces warnings identically to the router: plain English, no raw YAML
  # dumps, one batched ask, silent skip when empty.
  assert_present "[$tier] surfaces warnings like the router" '/ynab-review'
  assert_present_re "[$tier] warnings translated to plain English" 'plain.English'
  assert_present_re "[$tier] never dumps raw YAML" 'never dump raw YAML'
  assert_present_re "[$tier] batches decisions into a single ask" \
    'single.{0,30}AskUserQuestion'
  assert_present_flat_re "[$tier] empty warnings proceed silently" \
    'If .warnings. is empty, proceed silently'

  # Executes its own wrapper via the plugin-root variable.
  # shellcheck disable=SC2016
  assert_present "[$tier] runs its wrapper via \${CLAUDE_PLUGIN_ROOT}" \
    "\${CLAUDE_PLUGIN_ROOT}/skills/review/${tier}-ynab-review.md"
  assert_absent_re "[$tier] no hardcoded absolute/relative wrapper path" \
    '(/Users/|\.\./)[^ ]*skills/review/'

  check_shared "$tier"
done

# ---- summary -------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
