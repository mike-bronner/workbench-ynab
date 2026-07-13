#!/usr/bin/env bash
#
# persona-loader.test.sh — verifies the persona loader + renderers (issue #36).
#
# Self-contained: no test framework required. Run directly:
#   bash tests/persona-loader.test.sh
# Exits 0 if all assertions pass, 1 otherwise. Suitable for CI once the
# Sprint-1 test harness lands; until then it is the documented automated check
# behind docs/persona.md "Verification".
#
# Drives bin/persona.sh against temp configs via the YNAB_CONFIG_FILE and
# WORKBENCH_CORE_CONFIG_FILE overrides so the real plugin data dirs are never
# touched — the tests are hermetic and do not depend on host config state.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PERSONA_SH="${REPO_ROOT}/bin/persona.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# A guaranteed-absent path, used to pin "no config here" deterministically.
NO_FILE="${TMPDIR_TEST}/does-not-exist.json"

pass=0
fail=0

# run <ynab-cfg> <core-cfg> [args...] — invoke persona.sh with both config paths
# pinned, so neither tier leaks in from the host environment.
run() {
  local ynab="$1" core="$2"; shift 2
  YNAB_CONFIG_FILE="$ynab" WORKBENCH_CORE_CONFIG_FILE="$core" bash "$PERSONA_SH" "$@"
}

# assert_name <desc> <expected> <ynab-cfg> [core-cfg]
assert_name() {
  local desc="$1" expected="$2" ynab="$3" core="${4:-$NO_FILE}" got
  got="$(run "$ynab" "$core" name)"
  if [ "$got" = "$expected" ]; then
    printf 'ok   — %s (got %q)\n' "$desc" "$got"
    pass=$((pass + 1))
  else
    printf 'FAIL — %s: expected %q, got %q\n' "$desc" "$expected" "$got"
    fail=$((fail + 1))
  fi
}

# assert_contains <desc> <needle> <haystack>
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      printf 'ok   — %s\n' "$desc"; pass=$((pass + 1)) ;;
    *)
      printf 'FAIL — %s: %q not found in %q\n' "$desc" "$needle" "$haystack"
      fail=$((fail + 1)) ;;
  esac
}

# assert_absent <desc> <needle> <haystack>
assert_absent() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      printf 'FAIL — %s: %q unexpectedly present in %q\n' "$desc" "$needle" "$haystack"
      fail=$((fail + 1)) ;;
    *)
      printf 'ok   — %s\n' "$desc"; pass=$((pass + 1)) ;;
  esac
}

# ---- name resolution ----------------------------------------------------------

# (1) tier 1: explicit ynab persona.name is picked up
ynab_calvin="${TMPDIR_TEST}/ynab-calvin.json"
printf '{"persona":{"name":"Calvin"}}' > "$ynab_calvin"
assert_name "tier 1: ynab persona.name is picked up" "Calvin" "$ynab_calvin"

# (2) absent ynab config + absent core config falls back to Hobbes (no error)
assert_name "absent both configs falls back to Hobbes" "Hobbes" "$NO_FILE"

# (3) missing .persona.name field + no core falls back to Hobbes
ynab_empty="${TMPDIR_TEST}/ynab-empty.json"
printf '{"persona":{}}' > "$ynab_empty"
assert_name "missing persona.name falls back to Hobbes" "Hobbes" "$ynab_empty"

# (4) null .persona.name + no core falls back to Hobbes (documented guarantee)
ynab_null="${TMPDIR_TEST}/ynab-null.json"
printf '{"persona":{"name":null}}' > "$ynab_null"
assert_name "null persona.name falls back to Hobbes" "Hobbes" "$ynab_null"

# (5) malformed ynab JSON + no core falls back to Hobbes (no error)
ynab_bad="${TMPDIR_TEST}/ynab-bad.json"
printf 'this is not json {' > "$ynab_bad"
assert_name "malformed config falls back to Hobbes" "Hobbes" "$ynab_bad"

# (6) tier 2: no ynab persona.name, core agent_name present -> agent's name
core_holmes="${TMPDIR_TEST}/core-holmes.json"
printf '{"agent_name":"Holmes"}' > "$core_holmes"
assert_name "tier 2: core agent_name used as default" "Holmes" "$NO_FILE" "$core_holmes"
assert_name "tier 2: applies when ynab persona.name missing" "Holmes" "$ynab_empty" "$core_holmes"

# (7) precedence: ynab persona.name wins over core agent_name
assert_name "tier 1 beats tier 2 (ynab persona.name wins)" "Calvin" "$ynab_calvin" "$core_holmes"

# (8) whitespace-only persona.name is treated as empty and falls through.
#     Tier 1 is blank-but-present, tier 2 (core) supplies the real name.
ynab_blank="${TMPDIR_TEST}/ynab-blank.json"
printf '{"persona":{"name":"   "}}' > "$ynab_blank"
assert_name "whitespace-only persona.name falls through to tier 2" "Holmes" "$ynab_blank" "$core_holmes"
assert_name "whitespace-only persona.name + no core falls back to Hobbes" "Hobbes" "$ynab_blank"

# (9) jq missing on PATH: the loader's `command -v jq` guard makes the read
#     collapse to empty, so a present-but-unreadable config falls back to Hobbes.
#     Pin a minimal PATH that carries the externals persona.sh needs (dirname,
#     cat, date) but NOT jq, and invoke bash by absolute path so the launch
#     itself does not depend on the stripped PATH.
nojq_bin="${TMPDIR_TEST}/nojq-bin"
mkdir -p "$nojq_bin"
for _cmd in dirname cat date; do
  _real="$(command -v "$_cmd" || true)"
  [ -n "$_real" ] && ln -s "$_real" "$nojq_bin/$_cmd"
done
BASH_BIN="$(command -v bash)"
got_nojq="$(PATH="$nojq_bin" YNAB_CONFIG_FILE="$ynab_calvin" WORKBENCH_CORE_CONFIG_FILE="$NO_FILE" "$BASH_BIN" "$PERSONA_SH" name)"
if [ "$got_nojq" = "Hobbes" ]; then
  printf 'ok   — jq missing on PATH falls back to Hobbes (got %q)\n' "$got_nojq"; pass=$((pass + 1))
else
  printf 'FAIL — jq missing on PATH: expected "Hobbes", got %q\n' "$got_nojq"; fail=$((fail + 1))
fi

# ---- footer rendering (AC 7) --------------------------------------------------

footer="$(run "$ynab_calvin" "$NO_FILE" footer 2026-06-19)"
assert_contains "footer substitutes the resolved name"      "Generated by Calvin" "$footer"
assert_contains "footer substitutes the timestamp"          "2026-06-19"          "$footer"
assert_absent   "footer leaves no {{persona}} placeholder"  "{{persona}}"         "$footer"
assert_absent   "footer carries no hardcoded Hobbes literal" "Hobbes"             "$footer"

# tier-3 render: both configs absent -> the footer emits Hobbes, no token leak.
footer_t3="$(run "$NO_FILE" "$NO_FILE" footer 2026-06-19)"
assert_contains "tier-3 footer emits the Hobbes fallback"   "Generated by Hobbes" "$footer_t3"
assert_absent   "tier-3 footer leaves no {{persona}} placeholder" "{{persona}}"    "$footer_t3"

# HTML escaping: the footer is an HTML fragment, so an ordinary name with `&`
# must render as a valid entity, and markup must be neutralised, not injected.
ynab_amp="${TMPDIR_TEST}/ynab-amp.json"
printf '{"persona":{"name":"Smith & Sons"}}' > "$ynab_amp"
footer_amp="$(run "$ynab_amp" "$NO_FILE" footer 2026-06-19)"
assert_contains "footer HTML-escapes & in an ordinary name" "Generated by Smith &amp; Sons" "$footer_amp"
assert_absent   "footer emits no raw unescaped ampersand"   "Smith & Sons"                  "$footer_amp"

ynab_inj="${TMPDIR_TEST}/ynab-inj.json"
printf '{"persona":{"name":"x</p><script>"}}' > "$ynab_inj"
footer_inj="$(run "$ynab_inj" "$NO_FILE" footer 2026-06-19)"
assert_contains "footer escapes markup to entities"         "x&lt;/p&gt;&lt;script&gt;"     "$footer_inj"
assert_absent   "footer injects no raw markup from the name" "x</p>"                         "$footer_inj"

# All five escapable characters at once (& < > " '). Guards AC-1/AC-3: the quote
# and apostrophe entities must render too, and — because this runs on the bash 5
# CI runner — it exercises the exact `&`-as-matched-text hazard (#126) end to end
# through the real substitution path, which the pre-fix code could not survive.
ynab_all="${TMPDIR_TEST}/ynab-all.json"
printf '%s' '{"persona":{"name":"O'\''Reilly & \"Q\" <x>"}}' > "$ynab_all"
footer_all="$(run "$ynab_all" "$NO_FILE" footer 2026-06-19)"
assert_contains "footer escapes all of & < > \" ' to entities" \
  "Generated by O&#39;Reilly &amp; &quot;Q&quot; &lt;x&gt;" "$footer_all"
assert_absent   "footer leaks no raw quote+markup from the name" '"Q" <x>' "$footer_all"

# The {{generated_at}} value must be escaped too — AC-2 covers the fix "for
# BOTH" placeholders. Every other footer call above passes a plain date, so this
# is the only assertion that drives an escapable value through the
# {{generated_at}} splice path; without it, reverting just that splice to
# `${template//…}` would sail through the suite green on the bash-5 runner.
footer_when="$(run "$ynab_calvin" "$NO_FILE" footer 'Q1 & "2026" <b>')"
assert_contains "footer HTML-escapes the {{generated_at}} value too" \
  'Q1 &amp; &quot;2026&quot; &lt;b&gt;' "$footer_when"
assert_absent   "footer emits no raw markup from the timestamp value" '& "2026" <b>' "$footer_when"

# Adversarial persona name carrying a literal {{generated_at}} token. A chain of
# first-occurrence splices would let the token smuggled in by the {{persona}}
# splice hijack the {{generated_at}} splice — landing the date in the wrong spot
# and leaking the REAL trailing placeholder. A single left-to-right render treats
# the token as inert data: the real {{generated_at}} is still filled, in the
# right place, and no unfilled placeholder survives (#126 review blocker #1).
ynab_tok="${TMPDIR_TEST}/ynab-token.json"
printf '%s' '{"persona":{"name":"pwned {{generated_at}} pwned"}}' > "$ynab_tok"
footer_tok="$(run "$ynab_tok" "$NO_FILE" footer 2026-06-19)"
assert_contains "adversarial persona token does not hijack the date splice" \
  "pwned — 2026-06-19" "$footer_tok"
assert_absent   "no real {{generated_at}} placeholder leaks at the footer tail" \
  "— {{generated_at}}" "$footer_tok"

# ---- html-name subcommand (SLOT:footer-persona) -------------------------------

# The report chrome injects the persona name into `SLOT:footer-persona` as an
# already-escaped plain-text value. `html-name` renders it through the SAME
# tested `_html_escape` the footer uses, so the review skill injects it verbatim
# instead of re-implementing the escape (#126 review follow-up).
html_name_amp="$(run "$ynab_amp" "$NO_FILE" html-name)"
assert_contains "html-name HTML-escapes the resolved name"   "Smith &amp; Sons" "$html_name_amp"
assert_absent   "html-name emits no raw unescaped ampersand" "Smith & Sons"     "$html_name_amp"

html_name_inj="$(run "$ynab_inj" "$NO_FILE" html-name)"
assert_contains "html-name escapes markup in the name to entities" \
  "x&lt;/p&gt;&lt;script&gt;" "$html_name_inj"
assert_absent   "html-name injects no raw markup from the name" "x</p>" "$html_name_inj"

html_name_t3="$(run "$NO_FILE" "$NO_FILE" html-name)"
assert_contains "html-name emits the resolved name (Hobbes fallback)" "Hobbes" "$html_name_t3"

# ---- dispatch sign-off (AC 8) -------------------------------------------------

signoff="$(run "$ynab_calvin" "$NO_FILE" signoff)"
assert_contains "sign-off uses the resolved name"            "Calvin"             "$signoff"
assert_absent   "sign-off carries no hardcoded Hobbes literal" "Hobbes"           "$signoff"

# tier-3 render: both configs absent -> the sign-off emits the Hobbes fallback.
signoff_t3="$(run "$NO_FILE" "$NO_FILE" signoff)"
assert_contains "tier-3 sign-off emits the Hobbes fallback" "Hobbes"             "$signoff_t3"

# The sign-off is plain text, a different output context: it stays literal and
# is NOT HTML-escaped (verified by Holmes; locked here so it cannot regress).
signoff_amp="$(run "$ynab_amp" "$NO_FILE" signoff)"
assert_contains "sign-off keeps the name literal (plain-text context)" "Smith & Sons" "$signoff_amp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
