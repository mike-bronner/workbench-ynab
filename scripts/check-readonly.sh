#!/usr/bin/env bash
#
# scripts/check-readonly.sh — the M2 read-only static guardrail (issue #39).
#
# M2 is STRICTLY read-only: the review engine reproduces the proven analysis
# without ever mutating YNAB (writes are M3+). This script is the cheap,
# deterministic backstop that makes that boundary enforceable instead of
# aspirational — it fails the build if any M2 read-only surface can invoke a
# YNAB write, or references YNAB tools through the wrong (non-resolving)
# namespace. It runs in CI on every push (see .github/workflows/ci.yml) and via
# tests/check-readonly.test.sh, which pins its behaviour.
#
# WHAT IT CHECKS (two invariants)
#
#   1. NO WRITE VERB IS CALLABLE from an M2 read-only surface. The ten YNAB
#      write tools are:
#        ynab_update_transaction   ynab_update_transactions  ynab_update_category
#        ynab_create_transaction   ynab_create_transactions
#        ynab_create_receipt_split_transaction               ynab_delete_transaction
#        ynab_reconcile_account    ynab_create_account       ynab_set_default_budget
#
#      A write tool is only ever CALLABLE in its fully-namespaced form,
#      `mcp__plugin_workbench-ynab_ynab__<verb>` — that is the only string Claude
#      Code resolves to a live tool. So the gate matches the NAMESPACED (callable)
#      form, NOT a bare verb name. This is deliberate: the read-only orchestrator
#      (agents/ynab-orchestrator.md) names these verbs IN ITS OWN DENY-LIST PROSE
#      ("never call a write verb … `ynab_reconcile_account`"). Those bare mentions
#      are prohibitions, not calls — a bare-verb grep would fail the build on the
#      very file that enforces the boundary. Matching the callable form flags a
#      real invocation (or a write tool wired into an agent's `tools:` frontmatter)
#      while leaving read-only deny prose untouched.
#
#   2. EVERY YNAB TOOL REFERENCE IS NAMESPACED. A bare `mcp__ynab__…` reference
#      silently fails to resolve under the vendored/namespaced bundle, so any bare
#      occurrence in an M2 surface is a latent break — fail the build on it.
#
# SCAN SCOPE — the M2 read-only CONSUMER surfaces only
#
#   The review skills, the universal review protocol, the read-only orchestrator
#   agent, and the review command files. Deliberately EXCLUDED:
#     * skills/protocol/ynab-tools.md — the shared tool-catalog SSoT (issue #87);
#       it lists the namespaced write tools BY DESIGN (the full registry the M3+
#       write paths consume). It is not a caller.
#     * the M3+ write-path skills/assets and the money-gate guardrail — they
#       enumerate the write verbs precisely because gating them is their job.
#   Scoping to consumers is what keeps this gate free of false positives while
#   still proving no read-only surface can write.
#
# EXIT CODES
#   0  clean — no callable write verb and no bare namespace in any M2 surface
#   1  a violation was found (write verb callable, or bare namespace), OR a
#      required surface is missing (fail closed — a vanished file is never a pass)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The callable namespace prefix. A write tool is dangerous only in this form.
NS_PREFIX='mcp__plugin_workbench-ynab_ynab__'

# The ten M2-forbidden write verbs, as an ERE alternation. Longer names precede
# their prefixes so the alternation reads naturally; grep -E matches on presence
# either way (the gate only needs to DETECT a hit, not bound its extent).
WRITE_VERBS='ynab_update_transactions|ynab_update_transaction|ynab_update_category|ynab_create_transactions|ynab_create_receipt_split_transaction|ynab_create_transaction|ynab_create_account|ynab_delete_transaction|ynab_reconcile_account|ynab_set_default_budget'

# The callable-write pattern: the namespace prefix immediately followed by a
# forbidden verb. This is what a real invocation looks like; bare deny-prose
# ("`ynab_reconcile_account`") lacks the prefix and never matches.
CALLABLE_WRITE_RE="${NS_PREFIX}(${WRITE_VERBS})"

# A bare, non-resolving namespace. The correct prefix is mcp__plugin_workbench-ynab_ynab__,
# which does NOT contain the substring "mcp__ynab__", so this only ever matches
# the wrong form.
BARE_NS='mcp__ynab__'

# ── The M2 read-only consumer surfaces ─────────────────────────────────────────
# Enumerated files must exist; skills/review/*.md is a glob that must match ≥1.
enumerated=(
  "agents/ynab-orchestrator.md"      # the read-only planner/router agent
  "skills/protocol/SKILL.md"         # the universal 12-section review protocol
  "commands/ynab-review.md"          # the review router command
  "commands/ynab-weekly-review.md"
  "commands/ynab-monthly-review.md"
  "commands/ynab-quarterly-tax-review.md"
  "commands/ynab-annual-review.md"
)

surfaces=()
missing=()
for f in "${enumerated[@]}"; do
  if [ -f "$f" ]; then
    surfaces+=("$f")
  else
    missing+=("$f")
  fi
done

# The review skills, discovered by glob so a new review skill is covered with no
# edit here. At least one must exist — an empty match means the review surface
# vanished (or moved), which is a fail-closed condition, never a silent pass.
review_skills=()
while IFS= read -r f; do review_skills+=("$f"); done < <(
  find skills/review -maxdepth 1 -type f -name '*.md' | sort
)
if [ "${#review_skills[@]}" -eq 0 ]; then
  missing+=("skills/review/*.md (no review skill found)")
else
  surfaces+=("${review_skills[@]}")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  {
    echo "✖ read-only guardrail: expected M2 surface(s) not found — refusing to pass:"
    printf '    %s\n' "${missing[@]}"
    echo
    echo "  A vanished surface means the scan scope is stale; fix the scope before"
    echo "  this gate can certify the read-only boundary."
  } >&2
  exit 1
fi

status=0

# ── Invariant 1: no callable write verb ────────────────────────────────────────
write_hits="$(grep -nE "$CALLABLE_WRITE_RE" "${surfaces[@]}" 2>/dev/null || true)"
if [ -n "$write_hits" ]; then
  {
    echo "✖ read-only guardrail: a YNAB WRITE tool is callable from an M2 read-only surface:"
    printf '%s\n' "$write_hits" | sed 's/^/    /'
    echo
    echo "  M2 is read-only. A ${NS_PREFIX}<write-verb> reference is a live"
    echo "  invocation — writes belong to the M3+ write paths, never here."
  } >&2
  status=1
fi

# ── Invariant 2: every YNAB tool reference is namespaced ────────────────────────
bare_hits="$(grep -nF "$BARE_NS" "${surfaces[@]}" 2>/dev/null || true)"
if [ -n "$bare_hits" ]; then
  {
    echo "✖ read-only guardrail: a bare, non-resolving '${BARE_NS}' reference was found:"
    printf '%s\n' "$bare_hits" | sed 's/^/    /'
    echo
    echo "  Every YNAB tool reference must use the ${NS_PREFIX}* namespace;"
    echo "  the bare form silently fails to resolve under the vendored bundle."
  } >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "✓ read-only guardrail: no callable write verb, no bare namespace across ${#surfaces[@]} M2 surface(s)."
fi
exit "$status"
