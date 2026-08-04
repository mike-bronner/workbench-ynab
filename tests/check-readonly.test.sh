#!/usr/bin/env bash
#
# check-readonly.test.sh — self-test for the M2 read-only guardrail (issue #39).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/check-readonly.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Auto-discovered by scripts/test.sh.
#
# The guard (scripts/check-readonly.sh) enforces two M2 invariants: no CALLABLE
# (namespaced) YNAB write tool on a read-only surface, and no bare `mcp__ynab__`
# reference. This file is the test for the test — it proves the guard:
#   * catches a namespaced write verb planted in a review skill, the orchestrator,
#     and a review command;
#   * catches a bare `mcp__ynab__` reference;
#   * does NOT flag the orchestrator's own read-only DENY-LIST prose (a bare
#     `ynab_reconcile_account` / a `ynab_update_*` family glob) — the exact
#     false-positive this design avoids;
#   * does NOT flag a namespaced READ tool (read tools are allowed);
#   * fails closed when a scanned surface is missing;
#   * and passes on the REAL repository tree (so a real regression fails CI here).
#
# It ALSO pins the guard's deny-list itself (issue #254). The guard's WRITE_VERBS
# and the money gate's ALLOWED_TOOLS ∪ DENIED_TOOLS (assets/write-safety-guardrail.js)
# are two independently-maintained copies of ONE invariant — which verbs mutate
# YNAB. Nothing used to prove they agree, so a verb silently dropped from
# WRITE_VERBS would leave every scanned surface unguarded for it and still pass
# CI. This file therefore:
#   * cross-checks WRITE_VERBS against the authoritative inventory and fails on
#     ANY divergence (in either direction);
#   * fails CLOSED when either list cannot be read or parses empty — a check that
#     cannot read its inputs must never certify them;
#   * and exercises EVERY verb in the inventory individually through the guard —
#     namespaced form caught, bare deny-prose form not flagged — instead of
#     probing only the one hardcoded WRITE_CALL.
#
# The concrete namespaced write token is assembled at runtime from two harmless
# fragments — the bare prefix and a verb suffix — so THIS file contains no literal
# concrete tool name and stays clean when bin/check-tool-name-sources.sh scans
# tests/. The per-verb suffixes are likewise read at runtime out of the two
# allowlisted files, never inlined here.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/../scripts/check-readonly.sh"
INVENTORY="$SELF_DIR/../assets/write-safety-guardrail.js"   # the authoritative mutating-tool inventory

# shellcheck source=/dev/null
source "$SELF_DIR/lib/mutating-inventory.sh"          # mutating_inventory_verbs + the bare prefix

PREFIX="$YNAB_TOOL_PREFIX"                            # the callable namespace prefix
WRITE_CALL="${PREFIX}ynab_update_transaction"         # a callable write tool (assembled)
READ_CALL="${PREFIX}ynab_list_transactions"           # a callable READ tool (allowed)
GLOB="ynab_update_*"                                  # a deny-prose family glob (not callable)
BARE='mcp__ynab__'                                    # the non-resolving bare namespace

SANDBOX="$(mktemp -d)"
SCRATCH="$(mktemp -d)"          # mutated guard copies for the drift-regression cases
trap 'rm -rf "$SANDBOX" "$SCRATCH"' EXIT

pass=0
fail=0

# ── The WRITE_VERBS ↔ authoritative-inventory cross-check (issue #254) ─────────
#
# Both extractors are awk, not sed: BSD sed (macOS, the primary dev platform) has
# no BRE alternation, so a `\(A\|B\)` range silently matches nothing there — which
# is precisely the fail-open a guard's guard must not have.

# extract_guard_verbs <guard-file> — the guard's WRITE_VERBS alternation, one
# bare verb per line, sorted. Non-zero if the file is unreadable.
extract_guard_verbs() {
  [ -f "$1" ] || return 1
  awk -F"'" '
    /^WRITE_VERBS=/ {
      n = split($2, verbs, "|")
      for (i = 1; i <= n; i++) if (verbs[i] != "") print verbs[i]
    }
  ' "$1" | sort -u
}

# The inventory side of the cross-check — ALLOWED_TOOLS ∪ DENIED_TOOLS, bare
# verbs, sorted — comes from tests/lib/mutating-inventory.sh's
# `mutating_inventory_verbs`, shared with the tests that pin the inventory's
# other mirrors (#257) so this extractor is not itself duplicated per mirror.

# cross_check <guard-file> <inventory-file>
#   0 — the two lists agree exactly
#   1 — they diverge (a verb in one and not the other, either direction)
#   2 — an input was unreadable or parsed empty: FAIL CLOSED. The emptiness test
#       below is what guarantees that for BOTH sides; the extractors' own
#       early-outs are a quieter route to the same answer (they spare the run a
#       stray awk stderr line). Without the emptiness test, a renamed or
#       reformatted inventory
#       would parse to "" on BOTH sides, compare equal, and report a green
#       cross-check that had verified nothing.
cross_check() {
  local guard_verbs inventory_verbs
  guard_verbs="$(extract_guard_verbs "$1")" || return 2
  inventory_verbs="$(mutating_inventory_verbs "$2")" || return 2
  [ -n "$guard_verbs" ] && [ -n "$inventory_verbs" ] || return 2
  [ "$guard_verbs" = "$inventory_verbs" ]
}

# write_guard_without <verb> <out> — a guard copy with <verb> dropped from
# WRITE_VERBS, rebuilding the alternation so dropping the LAST verb works too
# (a naive "s/verb|//" would leave that one silently intact).
write_guard_without() {
  awk -F"'" -v drop="$1" -v q="'" '
    /^WRITE_VERBS=/ {
      n = split($2, verbs, "|"); kept = ""
      for (i = 1; i <= n; i++) {
        if (verbs[i] == drop) continue
        kept = (kept == "" ? verbs[i] : kept "|" verbs[i])
      }
      print "WRITE_VERBS=" q kept q; next
    }
    { print }
  ' "$GUARD" > "$2"
}

# write_guard_with <verb> <out> — a guard copy with an EXTRA verb appended to
# WRITE_VERBS, for the opposite drift direction.
write_guard_with() {
  awk -F"'" -v add="$1" -v q="'" '
    /^WRITE_VERBS=/ { print "WRITE_VERBS=" q $2 "|" add q; next }
    { print }
  ' "$GUARD" > "$2"
}

# assert_rc "<desc>" <expected-rc> <actual-rc> — for the non-sandbox assertions.
# Asserts the EXACT code, never merely "non-zero": "diverged" (1) and "could not
# read the inputs" (2) are different failures, and a test that conflated them
# would still pass if the fail-closed path were removed.
assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (rc $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected rc $expected, got $actual"
    fail=$((fail + 1))
  fi
}

# Lay down a minimal but COMPLETE set of M2 read-only surfaces so the guard's
# fail-closed "surface missing" path is not tripped unless a case removes one.
reset_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/agents" "$SANDBOX/skills/protocol" \
           "$SANDBOX/skills/review" "$SANDBOX/commands"
  cp "$GUARD" "$SANDBOX/scripts/check-readonly.sh"
  chmod +x "$SANDBOX/scripts/check-readonly.sh"
  : > "$SANDBOX/agents/ynab-orchestrator.md"
  : > "$SANDBOX/skills/protocol/SKILL.md"
  : > "$SANDBOX/skills/review/ynab-review.md"
  : > "$SANDBOX/commands/ynab-review.md"
  : > "$SANDBOX/commands/ynab-weekly-review.md"
  : > "$SANDBOX/commands/ynab-monthly-review.md"
  : > "$SANDBOX/commands/ynab-quarterly-tax-review.md"
  : > "$SANDBOX/commands/ynab-annual-review.md"
  : > "$SANDBOX/commands/ynab-portfolio.md"
}

# run_case "<desc>" <expected-exit> <file-relative-to-sandbox> "<content>"
# An empty <file> writes nothing (used for the clean-tree case).
run_case() {
  local desc="$1" expected="$2" file="$3" content="$4"
  reset_sandbox
  if [ -n "$file" ]; then
    mkdir -p "$SANDBOX/$(dirname "$file")"
    printf '%s\n' "$content" > "$SANDBOX/$file"
  fi
  local actual=0
  ( cd "$SANDBOX" && bash scripts/check-readonly.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

# run_case_rm "<desc>" <expected-exit> <file-to-delete>
# Proves the fail-closed path: a required surface is removed before the run.
run_case_rm() {
  local desc="$1" expected="$2" file="$3"
  reset_sandbox
  rm -f "$SANDBOX/$file"
  local actual=0
  ( cd "$SANDBOX" && bash scripts/check-readonly.sh ) >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ $desc (exit $actual)"
    pass=$((pass + 1))
  else
    echo "  ✖ $desc — expected exit $expected, got $actual"
    fail=$((fail + 1))
  fi
}

echo "Self-test: a callable write verb on any read-only surface is caught"
run_case "callable write verb in a review skill is caught"  1 "skills/review/ynab-review.md"        "call $WRITE_CALL to fix it"
run_case "callable write verb in the orchestrator is caught" 1 "agents/ynab-orchestrator.md"        "tools: [$WRITE_CALL]"
run_case "callable write verb in a review command is caught" 1 "commands/ynab-weekly-review.md"     "runs $WRITE_CALL"
run_case "callable write verb in the protocol skill is caught" 1 "skills/protocol/SKILL.md"         "then $WRITE_CALL"

echo "Self-test: a bare (non-resolving) namespace is caught"
run_case "bare mcp__ynab__ in a review skill is caught"     1 "skills/review/ynab-review.md"        "fetch via ${BARE}ynab_list_transactions"

echo "Self-test: read-only deny prose and read tools are NOT flagged"
# The exact false-positive this design avoids: the orchestrator names write verbs
# in its OWN deny-list. A bare verb and a family glob are prohibitions, not calls.
run_case "deny-prose bare write verb is not flagged"        0 "agents/ynab-orchestrator.md"         "never call a write verb (\`ynab_reconcile_account\`)"
run_case "deny-prose family glob is not flagged"            0 "agents/ynab-orchestrator.md"         "never call \`$GLOB\` — read-only"
run_case "a namespaced READ tool is not flagged"            0 "agents/ynab-orchestrator.md"         "tools: [$READ_CALL]"
run_case "clean tree passes"                                0 ""                                    ""

echo "Self-test: fail closed when a required surface is missing"
run_case_rm "missing orchestrator fails closed"             1 "agents/ynab-orchestrator.md"
run_case_rm "missing protocol skill fails closed"           1 "skills/protocol/SKILL.md"
run_case_rm "missing a review command fails closed"         1 "commands/ynab-annual-review.md"
# The cross-budget rollup command (M6-7) is a read-only surface too — removing it
# must fail closed, which is only true while it stays in the guard's enumeration.
run_case_rm "missing the portfolio command fails closed"    1 "commands/ynab-portfolio.md"
run_case_rm "no review skill at all fails closed"           1 "skills/review/ynab-review.md"

echo "Self-test: WRITE_VERBS is pinned to the authoritative mutating-tool inventory"
# The pin itself, on the real tree. A divergence here means the guard's deny-list
# and the money gate's inventory have drifted apart — one of them is wrong.
cross_rc=0
cross_check "$GUARD" "$INVENTORY" || cross_rc=$?
assert_rc "guard WRITE_VERBS == inventory (ALLOWED_TOOLS ∪ DENIED_TOOLS)" 0 "$cross_rc"
if [ "$cross_rc" -ne 0 ]; then
  echo "    divergence (< guard only, > inventory only):"
  diff <(extract_guard_verbs "$GUARD") <(mutating_inventory_verbs "$INVENTORY") \
    | sed 's/^/      /' || true
fi

# The cross-check must fail closed on inputs it cannot read — otherwise a renamed
# or reformatted inventory silently reduces it to "" == "" and it certifies nothing.
rc=0; cross_check "$SCRATCH/no-such-guard.sh" "$INVENTORY" || rc=$?
assert_rc "unreadable guard fails closed (not a silent pass)" 2 "$rc"
rc=0; cross_check "$GUARD" "$SCRATCH/no-such-inventory.js" || rc=$?
assert_rc "unreadable inventory fails closed (not a silent pass)" 2 "$rc"
: > "$SCRATCH/empty-inventory.js"
rc=0; cross_check "$GUARD" "$SCRATCH/empty-inventory.js" || rc=$?
assert_rc "unparseable inventory fails closed (not a silent pass)" 2 "$rc"

# The regression that motivated the pin (issue #254): drop a verb from WRITE_VERBS
# WITHOUT touching the inventory. Before this cross-check existed the whole suite
# still passed 15/15. The dropped verb is read from the inventory rather than
# hardcoded, so this stays honest if the write surface ever changes.
drop_verb="$(mutating_inventory_verbs "$INVENTORY" | head -1)"
if [ -z "$drop_verb" ]; then
  echo "  ✖ cannot run the drift regression — the inventory parsed to no verbs"
  fail=$((fail + 1))
else
  write_guard_without "$drop_verb" "$SCRATCH/guard-dropped.sh"
  rc=0; cross_check "$SCRATCH/guard-dropped.sh" "$INVENTORY" || rc=$?
  assert_rc "dropping '$drop_verb' from WRITE_VERBS is caught as divergence" 1 "$rc"
fi
# The opposite direction: a verb in WRITE_VERBS that the inventory does not know.
# Proves the comparison is a set equality, not a one-sided subset test.
write_guard_with "ynab_not_a_real_verb" "$SCRATCH/guard-extra.sh"
rc=0; cross_check "$SCRATCH/guard-extra.sh" "$INVENTORY" || rc=$?
assert_rc "an extra verb in WRITE_VERBS is caught as divergence" 1 "$rc"

echo "Self-test: EVERY write verb in the inventory is individually caught"
# The original gap: only WRITE_CALL (one hardcoded verb) was ever probed, so
# every other verb could vanish from WRITE_VERBS undetected. Drive each verb through the
# guard in both forms — callable (must fail) and bare deny-prose (must pass).
INVENTORY_VERBS="$(mutating_inventory_verbs "$INVENTORY")"
verb_count=0
[ -n "$INVENTORY_VERBS" ] && verb_count="$(printf '%s\n' "$INVENTORY_VERBS" | wc -l | tr -d ' ')"
if [ "$verb_count" -eq 0 ]; then
  # A zero-length list would run zero cases and still report green — the exact
  # fail-open this section exists to close.
  echo "  ✖ the authoritative inventory parsed to 0 verbs — refusing to run 0 per-verb cases"
  fail=$((fail + 1))
else
  echo "  ($verb_count verb(s) read from the inventory)"
  while IFS= read -r verb; do
    [ -n "$verb" ] || continue
    run_case "callable $verb is caught"       1 "skills/review/ynab-review.md" "call ${PREFIX}${verb} to fix it"
    run_case "deny-prose $verb is not flagged" 0 "agents/ynab-orchestrator.md" "never call a write verb (\`$verb\`)"
  done <<EOF
$INVENTORY_VERBS
EOF
fi

# Mechanics proven above against the sandbox; this case proves the INVARIANT on
# the real tree — the actual M2 surfaces carry no callable write verb and no bare
# namespace. Because this is a tests/**/*.test.sh, scripts/test.sh runs it in CI,
# so a real read-only regression fails the build here, not just in the sandbox.
echo "Self-test: the real repository tree is clean"
real_out=""
real_rc=0
real_out="$( (cd "$SELF_DIR/.." && bash scripts/check-readonly.sh) 2>&1 )" || real_rc=$?
if [ "$real_rc" -eq 0 ]; then
  echo "  ✓ real tree passes the guard (exit 0)"
  pass=$((pass + 1))
else
  echo "  ✖ real tree FAILS the guard (exit $real_rc):"
  printf '%s\n' "$real_out" | sed 's/^/    /'
  fail=$((fail + 1))
fi

echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "✓ read-only guard self-test green."
