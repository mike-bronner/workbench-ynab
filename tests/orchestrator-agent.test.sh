#!/usr/bin/env bash
#
# orchestrator-agent.test.sh — verifies the fleshed ynab-orchestrator agent (issue #44).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/orchestrator-agent.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Style mirrors
# tests/review-wrappers.test.sh: raw bash, `set -u`, PASS/FAIL counters, a
# non-zero exit when anything fails. Auto-discovered by scripts/test.sh.
#
# The agent is a static markdown asset, so the assertions are structural string
# checks — the regression guard for the contract in issue #44 (as reconciled to
# the as-built architecture on the issue thread): restricted read-only tools
# frontmatter, boot patience, prompt-fed inputs (no config.json read), the
# date→tier eligibility rules with strict deterministic ordering, per-tier
# reasons/windows emitted through the EXISTING plan schema ynab-review.md
# consumes, anomaly detection as warnings, and the schedule-ownership statement.
# The smoke test extracts the "Clean scheduled run" worked-example plan block
# (known date 2026-04-13) and asserts it names the right tiers in the right
# order with the right window.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FILE="${REPO_ROOT}/agents/ynab-orchestrator.md"

pass=0
fail=0

# assert_present <desc> <needle> — the agent file must contain <needle> (literal).
assert_present() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$FILE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: %q not found\n' "$desc" "$needle"; fail=$((fail + 1))
  fi
}

# assert_present_re <desc> <regex> — the agent file must match <regex> (ERE).
assert_present_re() {
  local desc="$1" re="$2"
  if grep -qiE -- "$re" "$FILE"; then
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL — %s: /%s/ did not match\n' "$desc" "$re"; fail=$((fail + 1))
  fi
}

# assert_absent_re <desc> <regex> — the agent file must NOT match <regex> (ERE).
assert_absent_re() {
  local desc="$1" re="$2"
  if grep -qE -- "$re" "$FILE"; then
    printf 'FAIL — %s: /%s/ unexpectedly matched\n' "$desc" "$re"; fail=$((fail + 1))
  else
    printf 'ok   — %s\n' "$desc"; pass=$((pass + 1))
  fi
}

[ -f "$FILE" ] || { echo "FAIL — agent file missing: $FILE"; exit 1; }

# ── Frontmatter: identity + restricted read-only tools ─────────────────────────
# Concrete tool names live ONLY in skills/protocol/ynab-tools.md (the SSoT) and
# the guard-allowlisted files — so this test derives every expected name from
# the SSoT at runtime instead of inlining any (bin/check-tool-name-sources.sh
# enforces exactly that, tree-wide, including on this file).
assert_present    "frontmatter name"                       "name: ynab-orchestrator"
assert_present_re "frontmatter description"                "^description: .+"
TOOLS_LINE="$(grep -m1 '^tools:' "$FILE")"

SSOT="${REPO_ROOT}/skills/protocol/ynab-tools.md"
# block_after <heading-ERE> — print the first fenced code block after <heading>.
block_after() {
  awk -v h="$1" '$0 ~ h {f=1; next} f && /^```/ {c++; next} f && c==1 {print} f && c==2 {exit}' "$SSOT"
}
PREFIX="$(block_after '^## Prefix' | head -1)"
READ_TOOLS="$(block_after '^## Read tools')"
WRITE_TOOLS="$(block_after '^## Write tools')"
if [ -n "$PREFIX" ] && [ -n "$READ_TOOLS" ] && [ -n "$WRITE_TOOLS" ]; then
  printf 'ok   — SSoT prefix + read/write tool lists extracted\n'; pass=$((pass + 1))
else
  printf 'FAIL — could not extract tool lists from %s\n' "$SSOT"; fail=$((fail + 1))
fi

for t in Bash ToolSearch; do
  if printf '%s' "$TOOLS_LINE" | grep -qF -- "$t"; then
    printf 'ok   — tools list carries %s\n' "$t"; pass=$((pass + 1))
  else
    printf 'FAIL — tools list missing %s\n' "$t"; fail=$((fail + 1))
  fi
done

# The AC's named reads (budgets + transactions), resolved via the SSoT.
for suffix in list_budgets list_transactions; do
  name="$(printf '%s\n' "$READ_TOOLS" | grep -m1 -- "$suffix" || true)"
  if [ -n "$name" ] && printf '%s' "$TOOLS_LINE" | grep -qF -- "$name"; then
    printf 'ok   — tools list carries the SSoT %s read\n' "$suffix"; pass=$((pass + 1))
  else
    printf 'FAIL — tools list missing the SSoT %s read\n' "$suffix"; fail=$((fail + 1))
  fi
done

# Every namespaced tool the agent wires must be one of the SSoT's READ tools…
AGENT_MCP="$(printf '%s' "$TOOLS_LINE" | tr ',' '\n' | tr -d ' ' | grep -F -- "$PREFIX" || true)"
subset_ok=1
while IFS= read -r t; do
  [ -n "$t" ] || continue
  printf '%s\n' "$READ_TOOLS" | grep -qxF -- "$t" || { subset_ok=0; printf 'FAIL — %s is not an SSoT read tool\n' "$t"; }
done <<EOF
$AGENT_MCP
EOF
if [ "$subset_ok" -eq 1 ] && [ -n "$AGENT_MCP" ]; then
  printf 'ok   — every wired MCP tool is an SSoT read tool\n'; pass=$((pass + 1))
else
  fail=$((fail + 1))
fi

# …and never one of the SSoT's WRITE tools (structural read-only boundary).
write_hit=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  printf '%s\n' "$WRITE_TOOLS" | grep -qxF -- "$t" && { write_hit=1; printf 'FAIL — %s is an SSoT write tool\n' "$t"; }
done <<EOF
$AGENT_MCP
EOF
if [ "$write_hit" -eq 0 ]; then
  printf 'ok   — tools list carries no SSoT write tool\n'; pass=$((pass + 1))
else
  fail=$((fail + 1))
fi
# Belt-and-braces: no write-shaped verb in the allow-list at all.
if printf '%s' "$TOOLS_LINE" | grep -qE 'ynab_(update|create|delete|reconcile)'; then
  printf 'FAIL — tools list carries a write verb\n'; fail=$((fail + 1))
else
  printf 'ok   — tools list carries no write verb\n'; pass=$((pass + 1))
fi
assert_absent_re "no bare mcp__ynab__ namespace anywhere"  'mcp__ynab__'

# ── Boot patience (bujo pattern) ───────────────────────────────────────────────
BUDGETS_TOOL="$(printf '%s\n' "$READ_TOOLS" | grep -m1 -- list_budgets || true)"
assert_present    "ToolSearch select before first MCP call" "ToolSearch(query=\"select:${BUDGETS_TOOL}\""
assert_present    "sleep-2 retry backoff"                   'sleep 2'
assert_present_re "up to 10 retries (~20s)"                 '10 (times|retries)'
assert_present    "InputValidationError is a schema miss"   "InputValidationError"
assert_present    "offline warning only after retries"      "ynab_mcp_offline"

# ── Inputs: prompt-fed, never config.json ──────────────────────────────────────
assert_present_re "today is a prompt input"                 'today.+ISO date'
assert_present_re "does not read config.json itself"        'You do .*not.* read .config\.json.'
assert_absent_re  "no plugin-data config path inlined"      'plugins/data/workbench-ynab'
assert_present_re "explicit review_scope stays authoritative" 'review_scope.*(authoritative|skip eligibility)'

# ── Tier eligibility: deterministic rules + strict ordering ───────────────────
assert_present    "strict deterministic tier ordering"      '[annual, quarterly-tax, monthly, weekly]'
assert_present_re "weekly default is Monday"                'weekly_day.*= *Monday|default Monday'
assert_present    "monthly fires on day 1"                  'today.day == 1'
assert_present_re "quarterly default due dates"             'Apr 15,? Jun 15,? Sep 15,? (and )?Jan 15'
assert_present    "quarterly trigger window: 7 days before through due date" 'from **7 days before** the due date **through the due date**'
assert_present    "7-day-edge boundary example (8 days out is not eligible)" '8 days before Apr 15, one day before its reminder window'
assert_present_re "annual early-January window"             'early.January'
assert_present    "annual window override name"             'annual_window'
assert_present_re "empty tier list is a valid plan"         'tiers: \[\]'

# ── Schedule ownership: computed here, never recomputed downstream ────────────
assert_present_re "consumers never recompute eligibility"   'never recompute'
assert_present_re "ownership names the consumers"           '(M2-3|universal review skill).*(M2-8|router)'

# ── Output schema: the as-built plan block ynab-review.md consumes ────────────
assert_present    "plan block root"                         "plan:"
assert_present_re "report.tiers field"                      '^  report:'
assert_present    "per-tier reasons map"                    "reasons:"
assert_present    "transactions window since_date"          "since_date:"
assert_present    "transactions window until_date"          "until_date:"
assert_present    "state_inspected field"                   "state_inspected:"
assert_present_re "warnings carry kind/detail/options"      'kind: .+'

# ── Anomaly detection: detect + report, never act ─────────────────────────────
assert_present    "missed weekly anomaly"                   "missed_weekly"
assert_present    "missed monthly anomaly"                  "missed_monthly"
assert_present    "unreminded quarterly anomaly"            "quarterly_due_soon"
assert_present    "missed-weekly threshold is 9 days"       'dated more than 9 days before'
assert_present    "missed-monthly threshold is 35 days"     'dated more than 35 days before'
assert_present    "quarterly reminder lookahead is 7 days"  'opens within the next 7 days'
assert_present_re "anomalies are report-only"               'detect (and|\+) report'

# ── Hard read-only enforcement ────────────────────────────────────────────────
assert_present_re "mutation impulse becomes a warning"      '(stop and add a warning|add a warning instead)'
assert_present_re "no user interaction"                     'No user interaction'

# ── Smoke test: worked-example plan block for a known date (2026-04-13) ───────
# Extract the first fenced yaml block after the "Clean scheduled run" label —
# anchored on the label, not the date content, so a future second block that
# happens to mention the same date can't silently concatenate — and assert it
# names the right tiers, in the right order, with the union window sized right.
EXAMPLE="$(awk '/^Clean scheduled run/{lbl=1; next} lbl && /^```yaml$/{inb=1; next} inb && /^```$/{exit} inb{print}' "$FILE")"
if [ -n "$EXAMPLE" ]; then
  printf 'ok   — Clean-scheduled-run worked-example plan block exists\n'; pass=$((pass + 1))
  if printf '%s' "$EXAMPLE" | grep -qF 'tiers: ["quarterly-tax", "weekly"]'; then
    printf 'ok   — known date yields [quarterly-tax, weekly] in strict order\n'; pass=$((pass + 1))
  else
    printf 'FAIL — known-date example does not carry tiers: ["quarterly-tax", "weekly"]\n'; fail=$((fail + 1))
  fi
  if printf '%s' "$EXAMPLE" | grep -qF 'since_date: "2026-01-01"' \
     && printf '%s' "$EXAMPLE" | grep -qF 'until_date: "2026-04-13"'; then
    printf 'ok   — union data_pull window spans Q1 period start through today\n'; pass=$((pass + 1))
  else
    printf 'FAIL — known-date example window is not 2026-01-01 → 2026-04-13\n'; fail=$((fail + 1))
  fi
  for field in "plan:" "budget:" "data_pull:" "report:" "reasons:" "warnings:" "state_inspected:"; do
    if printf '%s' "$EXAMPLE" | grep -qF -- "$field"; then
      printf 'ok   — known-date example carries %s\n' "$field"; pass=$((pass + 1))
    else
      printf 'FAIL — known-date example missing %s\n' "$field"; fail=$((fail + 1))
    fi
  done
else
  printf 'FAIL — no worked-example yaml block after the Clean scheduled run label\n'; fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
