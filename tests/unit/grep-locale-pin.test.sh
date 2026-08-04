#!/usr/bin/env bash
#
# tests/unit/grep-locale-pin.test.sh — pins the LC_ALL=C invariant on every
# content-scanning grep in the shipped shell scripts (issue #270).
#
# THE DEFECT
#
# Under a UTF-8 locale grep decodes its input as UTF-8. A byte sequence that is
# not valid UTF-8 — a lone continuation byte (0x80), a bare 0xFF, a truncated
# multibyte lead (0xC3 with nothing after it) — makes grep SILENTLY fail to match
# on that line. No error, no warning, exit 1 "not found". One stray byte hides
# content from a scanner. `LC_ALL=C` makes grep match bytes instead of characters
# and the match succeeds.
#
# This is a second, independent mechanism with the same effect as the NUL /
# `--binary-files` blind spot closed in #255/#262 — and it is not hypothetical:
# GitHub Actions' ubuntu runners set `LANG=C.UTF-8`, macOS shells default to a
# UTF-8 locale, and no workflow in .github/workflows/ overrides either.
#
# MEASURED per site, not assumed — the two greps fail by DIFFERENT mechanisms,
# so "is this site affected?" has to be answered per call site, not per platform:
#
#   * BSD grep 2.6.0-FreeBSD (the macOS runner, the primary dev platform):
#     EVERY scan pinned here is defeated by an invalid byte earlier on the line,
#     under C.UTF-8 and en_US.UTF-8 alike. Passes under LC_ALL=C.
#   * GNU grep 3.12 (the ubuntu runners): defeated at scripts/check-readonly.sh's
#     two scans, where the improperly-encoded file is classified BINARY and the
#     hit never reaches stdout usably. NOT defeated at bin/check-tool-name-
#     sources.sh (its --binary-files=text pre-empts that classification) or at
#     bin/report-writer.sh's `-o` scans, which match invalid bytes fine.
#     Separately, GNU is defeated on a negated bracket expression — the shape of
#     bin/secret-scan.sh's 64-hex rule, already pinned under #262.
#
# So the check-readonly cases below discriminate on BOTH lanes; the tool-name and
# report-writer cases discriminate only on the macOS lane. That asymmetry is why
# this file joins that lane rather than relying on the ubuntu lanes — without it,
# four of the six pins could be dropped with CI still green. The STATIC sweep
# discriminates everywhere, on every platform, and is what catches a NEW unpinned
# grep that no behavioural case knows to look for.
#
# bash-3.2-lane: the invalid-UTF-8 locale defect this file pins reproduces on BSD
# grep, not on the GNU grep of the ubuntu lanes, so the behavioural cases only
# discriminate on the macOS runner — the same "prove the BSD half of a works-on-
# both claim" reason tests/secret-scan.test.sh is a lane member (issue #231).
#
# Harness convention (issue #4): raw bash, sources tests/lib/assert.sh, test_*
# functions, run_tests. scripts/test.sh auto-discovers this file.
#
# This file assembles every concrete YNAB tool name at runtime from harmless
# fragments, so it contains no literal name and stays clean under
# bin/check-tool-name-sources.sh's scan of tests/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# A lone UTF-8 continuation byte: never valid on its own, in any position.
BAD_BYTE=$'\200'

# The ambient locale every behavioural case runs the guard under. This is the
# defect's precondition — the guards must be correct DESPITE it, which is the
# whole point of pinning LC_ALL=C at the call site rather than exporting it once
# in a wrapper the next caller forgets.
UTF8_LOCALE='en_US.UTF-8'

# Concrete tool names, assembled — never written literally here.
NS_PREFIX='mcp__plugin_workbench-ynab_ynab__'
CONCRETE_NAME="${NS_PREFIX}ynab_list_budgets"          # matched by the swap-ready guard
WRITE_CALL="${NS_PREFIX}ynab_update_transaction"       # a callable write verb

# ── The static sweep: no unpinned grep in the shipped shell scripts ────────────
#
# AC: `grep -rn "grep " bin/ scripts/ lib/ | grep -v LC_ALL` returns only
# reviewed-and-justified sites. There are currently NO justified exceptions, so
# this guard is absolute — an allowlist would only invite the drift it documents.
#
# hooks/session-warmup.sh is deliberately out of scope, not overlooked: its two
# greps are strict positive allowlists (`^[0-9]+\.[0-9]+\.[0-9]+$`) over a value
# the caller discards unless it matches. A locale artifact there can only make
# the filter STRICTER — the version is dropped and the hook stays silent — so it
# fails closed by construction and is not a member of this defect class.

# shell_scripts — every shipped shell script the invariant covers, repo-relative.
shell_scripts() {
  ( cd "$REPO_ROOT" && find bin scripts lib -type f -name '*.sh' 2>/dev/null | sort )
}

# unpinned_grep_lines — every non-comment line in those scripts that invokes
# grep without an LC_ALL=C prefix, as `file:line:text`.
#
# Mechanics: strip each `LC_ALL=C grep` occurrence from the line first, then ask
# whether any grep invocation still remains. Done that way round, a line holding
# BOTH a pinned and an unpinned grep is still caught — a plain "does the line
# mention LC_ALL?" check would let the pinned one vouch for its neighbour.
unpinned_grep_lines() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    LC_ALL=C grep -nE '(^|[^[:alnum:]_./-])grep[[:space:]]' "$REPO_ROOT/$f" \
      | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*#' \
      | LC_ALL=C sed 's/LC_ALL=C[[:space:]]\{1,\}grep//g' \
      | LC_ALL=C grep -E '(^|[^[:alnum:]_./-])grep[[:space:]]' \
      | LC_ALL=C sed "s|^|$f:|" || true
  done <<EOF
$(shell_scripts)
EOF
}

test_sweep_actually_scans_the_guard_files() {
  # The sweep's own precondition. A find that silently returned nothing would
  # make the invariant test below pass having scanned no file at all — the
  # vacuous green this whole issue is about.
  local scripts
  scripts="$(shell_scripts)"
  [ -n "$scripts" ] || fail "found no shell scripts under bin/ scripts/ lib/ — the sweep would assert nothing"
  assert_exact_line "$scripts" 'bin/check-tool-name-sources.sh' "the swap-ready guard must be in the sweep's scope"
  assert_exact_line "$scripts" 'bin/report-writer.sh' "the report writer must be in the sweep's scope"
  assert_exact_line "$scripts" 'bin/secret-scan.sh' "the secret scanner must be in the sweep's scope"
  assert_exact_line "$scripts" 'scripts/check-readonly.sh' "the read-only guardrail must be in the sweep's scope"
}

test_no_unpinned_grep_in_shipped_shell_scripts() {
  local hits
  hits="$(unpinned_grep_lines)"
  if [ -n "$hits" ]; then
    printf '  unpinned scanning grep(s) — prefix each with LC_ALL=C:\n%s\n' "$hits" >&2
    fail "every grep in bin/ scripts/ lib/ must run under LC_ALL=C (issue #270)"
  fi
}

test_sweep_detects_an_unpinned_grep() {
  # The sweep's own negative control: without it, `unpinned_grep_lines` could be
  # matching nothing at all (a broken regex, a bad path) and the invariant test
  # above would be green for the wrong reason. Plant an unpinned grep in a
  # throwaway tree and confirm the detector fires — and that a pinned one, and a
  # commented-out one, do not.
  local probe="$SANDBOX/sweepprobe"
  mkdir -p "$probe/bin"
  cat > "$probe/bin/probe.sh" <<'SH'
#!/usr/bin/env bash
# grep -E 'commented out' "$f"      <- a comment, never a call site
pinned="$(LC_ALL=C grep -c x "$1")"
loose="$(grep -c y "$1")"
both="$(LC_ALL=C grep -c a "$1"; grep -c b "$1")"
SH
  local hits
  hits="$( cd "$probe" && \
           LC_ALL=C grep -nE '(^|[^[:alnum:]_./-])grep[[:space:]]' bin/probe.sh \
             | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*#' \
             | LC_ALL=C sed 's/LC_ALL=C[[:space:]]\{1,\}grep//g' \
             | LC_ALL=C grep -E '(^|[^[:alnum:]_./-])grep[[:space:]]' )"
  assert_contains "$hits" 'grep -c y' "the sweep must flag a bare, unpinned grep"
  assert_contains "$hits" 'grep -c b' "the sweep must flag an unpinned grep sharing a line with a pinned one"
  case "$hits" in
    *'commented out'*) fail "the sweep flagged a commented-out grep — comments are not call sites" ;;
  esac
  # The pinned-only line must not appear at all: after stripping `LC_ALL=C grep`
  # nothing grep-shaped is left on it.
  case "$hits" in
    *'pinned='*) fail "the sweep flagged an already-pinned grep" ;;
  esac
}

# ── Behavioural: bin/check-tool-name-sources.sh ───────────────────────────────

test_tool_name_guard_sees_a_name_behind_an_invalid_utf8_byte() {
  # The swap-ready guard must still find a concrete tool name on a line that also
  # carries an invalid UTF-8 byte. Without the pin, BSD grep skips the line and
  # the guard reports a clean tree — a hard-coded tool name shipped unnoticed.
  local repo="$SANDBOX/toolname"
  rm -rf "$repo"
  mkdir -p "$repo/bin" "$repo/skills"
  cp "$REPO_ROOT/bin/check-tool-name-sources.sh" "$repo/bin/"
  printf 'prose %s%s and more prose\n' "$BAD_BYTE" "$CONCRETE_NAME" > "$repo/skills/smuggled.md"

  local rc=0 out
  out="$( LC_ALL="$UTF8_LOCALE" bash "$repo/bin/check-tool-name-sources.sh" 2>&1 )" || rc=$?
  assert_eq "1" "$rc" "the guard must fail on a tool name hidden behind an invalid UTF-8 byte"
  assert_contains "$out" 'skills/smuggled.md' "the guard must name the offending file"
}

test_tool_name_guard_still_passes_a_clean_tree_under_a_utf8_locale() {
  # The other half of the discrimination: pinning the locale must not turn the
  # guard into something that fails on everything. A tree whose only invalid
  # byte sits nowhere near a tool name is still clean.
  local repo="$SANDBOX/toolname-clean"
  rm -rf "$repo"
  mkdir -p "$repo/bin" "$repo/skills"
  cp "$REPO_ROOT/bin/check-tool-name-sources.sh" "$repo/bin/"
  printf 'ordinary prose %s with a stray byte\n' "$BAD_BYTE" > "$repo/skills/harmless.md"

  local rc=0
  ( LC_ALL="$UTF8_LOCALE" bash "$repo/bin/check-tool-name-sources.sh" >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "a tree with no tool name must still pass, stray byte or not"
}

# ── Behavioural: scripts/check-readonly.sh ────────────────────────────────────

# stage_readonly_sandbox <dir> — a sandbox holding the guard plus every M2
# surface it enumerates, copied from the real tree so the scan scope is the real
# one (the guard fails closed on a missing surface, so a partial copy would test
# the fail-closed path instead of the scan).
stage_readonly_sandbox() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/scripts"
  cp "$REPO_ROOT/scripts/check-readonly.sh" "$dir/scripts/"
  ( cd "$REPO_ROOT" && cp -R agents skills commands "$dir/" )
}

test_readonly_guard_sees_a_write_verb_behind_an_invalid_utf8_byte() {
  # A callable write verb on an M2 read-only surface, preceded on the same line
  # by an invalid UTF-8 byte. Without the pin, BSD grep skips the line: the gate
  # prints "✓ no callable write verb" and CI goes green on a real read-only
  # boundary violation.
  local dir="$SANDBOX/readonly"
  stage_readonly_sandbox "$dir"
  local surface
  surface="$( cd "$dir" && find skills/review -maxdepth 1 -type f -name '*.md' | sort | head -1 )"
  [ -n "$surface" ] || fail "no review skill found to plant into — the scan scope moved"
  printf 'call %s%s now\n' "$BAD_BYTE" "$WRITE_CALL" >> "$dir/$surface"

  local rc=0 out
  out="$( LC_ALL="$UTF8_LOCALE" bash "$dir/scripts/check-readonly.sh" 2>&1 )" || rc=$?
  assert_eq "1" "$rc" "the guardrail must fail on a write verb hidden behind an invalid UTF-8 byte"
  assert_contains "$out" 'WRITE tool is callable' "the guardrail must report the write-verb invariant, not some other failure"
  assert_contains "$out" "$surface" "the guardrail must name the offending surface"
}

test_readonly_guard_sees_a_bare_namespace_behind_an_invalid_utf8_byte() {
  # Invariant 2 is a separate grep call site with a separate pin, so it needs its
  # own case — fixing one scan's locale says nothing about its sibling's.
  local dir="$SANDBOX/readonly-bare"
  stage_readonly_sandbox "$dir"
  local surface
  surface="$( cd "$dir" && find skills/review -maxdepth 1 -type f -name '*.md' | sort | head -1 )"
  [ -n "$surface" ] || fail "no review skill found to plant into — the scan scope moved"
  # Assembled, so this file never contains the bare namespace literally either.
  printf 'see %s%s%s here\n' "$BAD_BYTE" 'mcp__' 'ynab__' >> "$dir/$surface"

  local rc=0 out
  out="$( LC_ALL="$UTF8_LOCALE" bash "$dir/scripts/check-readonly.sh" 2>&1 )" || rc=$?
  assert_eq "1" "$rc" "the guardrail must fail on a bare namespace hidden behind an invalid UTF-8 byte"
  assert_contains "$out" 'bare, non-resolving' "the guardrail must report the bare-namespace invariant"
}

test_readonly_guard_still_passes_the_staged_clean_tree() {
  # Negative control for both cases above: the staged copy is clean before
  # anything is planted, so a failure there would mean the two tests above pass
  # for a reason unrelated to what they plant.
  local dir="$SANDBOX/readonly-clean"
  stage_readonly_sandbox "$dir"
  local rc=0
  ( LC_ALL="$UTF8_LOCALE" bash "$dir/scripts/check-readonly.sh" >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "the staged surfaces must be clean before planting"
}

# ── Behavioural: bin/report-writer.sh ─────────────────────────────────────────

test_report_writer_sees_a_slot_marker_behind_an_invalid_utf8_byte() {
  # A template line carrying an invalid UTF-8 byte before a slot marker. All
  # three slot scans must still see that marker.
  #
  # Without the pin, BSD grep skips the line, so `hidden` never enters
  # required_slots — and supplying it is then rejected as an UNKNOWN slot name
  # (exit 2). With the pin the writer knows the slot, fills it, and exits 0 with
  # no raw marker left in the report. Exit code and marker-freedom are asserted
  # separately: exit 0 alone would also hold if the writer silently emitted the
  # marker verbatim.
  local dir="$SANDBOX/writer" tpl="$SANDBOX/writer-template.html"
  rm -rf "$dir"
  {
    printf '<!DOCTYPE html><html><head><title>{{tier}} %s</title></head><body>\n' '{{report_date}}'
    printf '<meta name="report-output-path" content="{{output_path}}"><p>{{tax_year}}</p>\n'
    printf '<section>%s<!-- SLOT:hidden --></section>\n' "$BAD_BYTE"
    printf '<section><!-- SLOT:visible --></section>\n'
    printf '</body></html>\n'
  } > "$tpl"

  local rc=0 out err
  out="$( YNAB_CONFIG_FILE="$SANDBOX/none.json" LC_ALL="$UTF8_LOCALE" bash "$REPO_ROOT/bin/report-writer.sh" \
            --template "$tpl" --output-dir "$dir" \
            --tier Weekly --date 2026-06-22 \
            --slot 'hidden=<div>h</div>' \
            --slot 'visible=<div>v</div>' 2>"$SANDBOX/writer.err" )" || rc=$?
  err="$(cat "$SANDBOX/writer.err")"
  assert_eq "0" "$rc" "the writer must accept a slot whose marker shares a line with an invalid UTF-8 byte (stderr: $err)"
  assert_file_exists "$out"
  local html
  html="$(cat "$out")"
  assert_contains "$html" '<div>h</div>' "the hidden slot must actually be filled"
  case "$html" in
    *'<!-- SLOT:'*) fail "the report still carries a raw slot marker — a slot was never seen by the scans" ;;
  esac
}

test_report_writer_still_rejects_a_malformed_marker_behind_an_invalid_utf8_byte() {
  # The malformed-template gate is one of the two counting scans. An unclosed
  # opener on a line that also carries an invalid UTF-8 byte must still be
  # refused loudly (exit 2, no file) rather than skipped into a balanced count.
  local dir="$SANDBOX/writer-malformed" tpl="$SANDBOX/writer-malformed.html"
  rm -rf "$dir"
  {
    printf '<!DOCTYPE html><html><head><title>{{tier}} %s</title></head><body>\n' '{{report_date}}'
    printf '<meta name="report-output-path" content="{{output_path}}"><p>{{tax_year}}</p>\n'
    printf '<section>%s<!-- SLOT:unclosed</section>\n' "$BAD_BYTE"
    printf '<section><!-- SLOT:visible --></section>\n'
    printf '</body></html>\n'
  } > "$tpl"

  local rc=0 err
  ( YNAB_CONFIG_FILE="$SANDBOX/none.json" LC_ALL="$UTF8_LOCALE" bash "$REPO_ROOT/bin/report-writer.sh" \
      --template "$tpl" --output-dir "$dir" \
      --tier Weekly --date 2026-06-22 \
      --slot 'visible=<div>v</div>' >/dev/null 2>"$SANDBOX/malformed.err" ) || rc=$?
  err="$(cat "$SANDBOX/malformed.err")"
  assert_eq "2" "$rc" "a malformed marker hidden behind an invalid UTF-8 byte must still be refused (stderr: $err)"
  assert_contains "$err" 'malformed' "the writer must report the malformed-template gate, not some other failure"
  [ -e "$dir/YNAB-Weekly-Review-2026-06-22.html" ] \
    && fail "the writer wrote a file despite a malformed template"
  return 0
}

run_tests
