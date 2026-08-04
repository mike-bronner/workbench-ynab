#!/usr/bin/env bash
#
# tests/unit/uninstall-command.test.sh — guards the /workbench-ynab:uninstall
# teardown command (commands/uninstall.md) and its by-hand mirror
# (docs/uninstall.md). Issue #67.
#
# A slash command is agent-executed prose, so a whole-file grep for a needle is
# hollow — the needle usually also occurs in the surrounding rationale, and the
# check stays green with the executable gate deleted. This file therefore uses
# the extract-and-RUN convention established by tests/unit/setup-command.test.sh:
# every removal step's fenced bash block is pulled out of the markdown and
# actually EXECUTED against a sandbox, once per branch, so each branch's
# behaviour is asserted from real output rather than from source text.
#
# What is pinned, by AC:
#   #2  scheduled-task removal — prose + MCP call (Step 2 section, scoped)
#   #3  Keychain removal — all FOUR branches executed, including `security`
#       genuinely absent from PATH (not merely a non-zero stub), and the
#       check-before-delete ordering proved by a delete-called marker
#   #4  settings.json — all FIVE branches executed: no file, unparseable file,
#       zero matches, real surgical removal (siblings + unrelated keys survive),
#       and both fail-closed rewrite failures leaving the file byte-identical
#   #5/#6 data directory — prompt content (scoped to its jsonc fence), and all
#       FOUR execution branches including a forced partial-delete
#   #7  token-revocation reminder (scoped to Step 6's fenced block)
#   #8  teardown summary naming every component and every outcome class
#   #9  docs/uninstall.md mirrors every automated step
#   #10 data-dir UX consistent with the issue #65 privacy posture
#
# The command file is NOT on bin/check-tool-name-sources.sh's allowlist, so it
# may only carry the bare plugin prefix, never a concrete tool name — that is
# asserted here too, since the guard itself cannot catch a *missing* prefix.
#
# Follows the repo harness convention (tests/lib/assert.sh): raw bash with
# `set -euo pipefail`, `test_*` functions, `run_tests`. Auto-discovered by
# scripts/test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

CMD="$REPO_ROOT/commands/uninstall.md"
DOC="$REPO_ROOT/docs/uninstall.md"

# The bare, guard-safe plugin prefix. Never a concrete tool name in this file.
PREFIX="mcp__plugin_workbench-ynab_ynab__"

REAL_JQ="$(command -v jq)"

# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------

# section_body <file> <heading-line-prefix> — every line of the section that
# starts with <heading-line-prefix>, from the line AFTER the heading up to the
# next "## " heading. The heading line itself is deliberately EXCLUDED: a
# heading restates its own section's topic words, so a heading-inclusive
# extraction lets the heading satisfy a check meant to pin the body.
section_body() {
  awk -v head="$2" '
    index($0, head) == 1 { s = 1; next }
    s && /^## / { exit }
    s { print }
  ' "$1"
}

# fenced_block <file> <heading-line-prefix> <lang> [n] — the Nth ```<lang>
# fenced block inside that section (default: the 1st). Deleting the block
# empties the output, so every assertion scoped to it then fails.
fenced_block() {
  awk -v head="$2" -v lang="$3" -v want="${4:-1}" '
    index($0, head) == 1 { s = 1; next }
    s && /^## / { exit }
    s && $0 == "```" lang { c++; if (c == want) f = 1; next }
    f && /^```$/ { exit }
    f { print }
  ' "$1"
}

constants_block() { fenced_block "$CMD" '## Constants' bash; }
doc_constants_block() { fenced_block "$DOC" '## Constants' bash; }

# Portable octal-perms read: GNU `stat -c '%a'` probed FIRST (on GNU, `stat -f`
# is "filesystem status" and misreads `%Lp`), BSD/macOS `stat -f '%Lp'` as the
# fallback. Same helper the report-writer / audit-log / setup-config-write
# suites use for mode-bit assertions.
#
# Deliberately NO `-L`, unlike the command's own capture: this is an lstat read,
# so on a symlink it reports the LINK's mode. test_symlink_fixture_can_discriminate
# depends on that — adding `-L` here for "consistency" with the command would make
# the symlink tests' precondition vacuous.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# ---------------------------------------------------------------------------
# Execution harness — run one extracted block in a sandbox
# ---------------------------------------------------------------------------
# run_block <sandbox-home> <block-text> [extra-env...] — prepend the Constants
# block (which defines $DATA_DIR/$SETTINGS/$KEYCHAIN_*/$TOOL_PREFIX from $HOME)
# and execute. Captures B_OUT / B_ERR. Never uses `set -e` inside the block:
# the command's steps are agent-run prose, and every one of them is written to
# continue past a failed component rather than abort the teardown — so the
# blocks' assertions are on what they REPORT, not on an exit code.
run_block() {
  local home="$1" block="$2"; shift 2
  local errf; errf="$(mktemp)"
  set +e
  # bash is invoked by ABSOLUTE path: the PATH a caller passes in constrains
  # what the extracted BLOCK can find, and a sandbox PATH that omits the shell
  # itself would fail before the block ever ran.
  B_OUT="$(env HOME="$home" "$@" "${BASH:-/bin/bash}" -c "$(constants_block)
$block" 2>"$errf")"
  set -e
  B_ERR="$(cat "$errf")"
  rm -f "$errf"
}

# ---------------------------------------------------------------------------
# Structure — the command registers and is guard-clean
# ---------------------------------------------------------------------------

# AC #1: the command file exists at the path that registers the slash command.
# A file at commands/<name>.md IS the /workbench-ynab:<name> registration, so
# the path and a non-empty frontmatter description are the whole contract.
test_command_registers_with_a_description() {
  assert_file_exists "$CMD"
  assert_eq "---" "$(head -n 1 "$CMD")" "first line is the frontmatter fence"
  grep -qE '^description:[[:space:]]*\S' "$CMD" \
    || fail "commands/uninstall.md has no non-empty 'description:' in its frontmatter"
}

# The command may carry only the BARE prefix — a concrete tool name here would
# fail bin/check-tool-name-sources.sh, and an absent prefix would make Step 4
# match nothing. The guard catches the first case tree-wide but not the second.
# AC #3 names the removal command literally, down to its service/account
# arguments. The command parameterises them through the Constants block (the
# setup.md convention), so pin the constants to the exact documented values —
# otherwise a renamed constant would silently target a different Keychain item
# while every behavioural branch above still passed against the stub.
test_keychain_constants_are_the_documented_service_and_account() {
  local consts; consts="$(constants_block)"
  assert_contains "$consts" 'KEYCHAIN_SERVICE="ynab-mcp"' "the Keychain service is ynab-mcp"
  assert_contains "$consts" 'KEYCHAIN_ACCOUNT="access-token"' "the Keychain account is access-token"
  local block; block="$(fenced_block "$CMD" '## Step 3 ' bash)"
  # shellcheck disable=SC2016  # literal command text, never expanded here
  assert_contains "$block" 'security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT"' \
    "Step 3 issues the AC's delete-generic-password call"
}

test_settings_filter_keys_on_the_bare_prefix() {
  local consts; consts="$(constants_block)"
  assert_contains "$consts" "TOOL_PREFIX=\"$PREFIX\"" \
    "the Constants block defines TOOL_PREFIX as the bare plugin-namespaced prefix"
  if grep -qE "${PREFIX}ynab_[a-z_]+" "$CMD"; then
    fail "commands/uninstall.md hard-codes a concrete tool name — it is not on the check-tool-name-sources allowlist"
  fi
}

# ---------------------------------------------------------------------------
# AC #3 — the Keychain step, all four branches EXECUTED
# ---------------------------------------------------------------------------
# The four branches are genuinely different code paths and each needs its own
# case. In particular, `security` absent from PATH is NOT the same path as a
# `security` stub returning non-zero: only the former reaches the `command -v`
# arm. A stub-exit-code-only suite never executes that arm at all.

# make_security_stub <dir> <find-rc> <delete-rc> <marker> — a `security` stub
# whose two subcommands return the given codes, and which records that
# delete-generic-password was reached by creating <marker>.
make_security_stub() {
  local dir="$1" find_rc="$2" del_rc="$3" marker="$4"
  mkdir -p "$dir"
  cat > "$dir/security" <<EOF
#!/usr/bin/env bash
case "\$1" in
  find-generic-password)   exit $find_rc ;;
  delete-generic-password) : > "$marker"; exit $del_rc ;;
esac
exit 99
EOF
  chmod +x "$dir/security"
}

# run_step3 <mode> — execute the Keychain block with a PATH holding ONLY the
# sandbox bin, so "absent" means the binary is truly unreachable. The block
# needs no external command other than `security` itself (`command -v` and
# `echo` are bash builtins), which is what makes that isolation faithful.
# Sets B_OUT / B_ERR / B_RC plus S3_DELETE_CALLED.
run_step3() {
  local mode="$1" sb; sb="$(mktemp -d)"
  mkdir -p "$sb/bin" "$sb/home"
  # The stubs' `#!/usr/bin/env bash` shebang resolves `bash` through the SANDBOX
  # PATH, so the shell has to be reachable there or every stub would fail with
  # 127 and masquerade as "entry not found". Linking it in declares bash as an
  # allowed tool; `security` is still genuinely absent in the `absent` mode.
  ln -s "${BASH:-/bin/bash}" "$sb/bin/bash"
  local marker="$sb/delete-called"
  case "$mode" in
    absent)         : ;;                                        # no stub at all
    missing_entry)  make_security_stub "$sb/bin" 44 0 "$marker" ;;
    delete_ok)      make_security_stub "$sb/bin" 0  0 "$marker" ;;
    delete_fails)   make_security_stub "$sb/bin" 0  36 "$marker" ;;
    *) fail "unknown run_step3 mode: $mode" ;;
  esac
  run_block "$sb/home" "$(fenced_block "$CMD" '## Step 3 ' bash)" PATH="$sb/bin"
  S3_DELETE_CALLED=0
  [ -f "$marker" ] && S3_DELETE_CALLED=1
  rm -rf "$sb"
}

# `security` genuinely missing from PATH — the command -v arm. Degrades to a
# manual step, and must NOT claim the entry is gone.
test_keychain_security_binary_absent_reports_manual() {
  run_step3 absent
  assert_contains "$B_ERR" "security CLI not on PATH" "the absent-binary arm names the cause"
  assert_contains "$B_ERR" "by hand" "the absent-binary arm hands the removal back to the user"
  case "$B_OUT" in
    *"removed"*) fail "claimed the Keychain entry was removed with no security binary present" ;;
    *"already clean"*) fail "claimed already-clean with no security binary present" ;;
  esac
}

# Entry absent — idempotent skip, and delete is never called (check-first).
test_keychain_absent_entry_skips_without_calling_delete() {
  run_step3 missing_entry
  assert_contains "$B_OUT" "Keychain entry not found — skipping" "reports the idempotent skip"
  assert_contains "$B_OUT" "already clean" "names it as already clean"
  assert_eq "0" "$S3_DELETE_CALLED" \
    "delete-generic-password must NOT run when find-generic-password says the entry is absent"
}

# Entry present and deletable — the happy path actually calls delete.
test_keychain_present_entry_is_removed() {
  run_step3 delete_ok
  assert_contains "$B_OUT" "Keychain entry removed" "reports the removal"
  assert_contains "$B_OUT" "ynab-mcp / access-token" "names the service and account removed"
  assert_eq "1" "$S3_DELETE_CALLED" "delete-generic-password must run when the entry is present"
}

# Entry present but delete FAILS (locked keychain) — fail closed. This is the
# branch a three-branch implementation collapses into "already clean", which
# would tell the user their token is gone while it is still stored.
test_keychain_failed_delete_fails_closed() {
  run_step3 delete_fails
  assert_eq "1" "$S3_DELETE_CALLED" "the failing branch did reach delete-generic-password"
  assert_contains "$B_ERR" "could not be deleted" "the failed delete is reported loudly on stderr"
  assert_contains "$B_ERR" "the token is still stored" "the user is told the token remains"
  case "$B_OUT" in
    *"Keychain entry removed"*) fail "a failed delete was reported as a successful removal" ;;
    *"already clean"*)          fail "a failed delete was swallowed as already-clean" ;;
  esac
}

# ---------------------------------------------------------------------------
# AC #4 — the settings.json step, all five branches EXECUTED
# ---------------------------------------------------------------------------

# A settings file with our entries mixed among entries that MUST survive:
# a sibling plugin's tools, a bare Bash permission, a deny list, an unrelated
# top-level key — and one NON-STRING element. Anything but a prefix-scoped
# filter disturbs one of them; a filter without the `type == "string"` test
# errors out on the non-string element and abandons the whole removal.
write_settings() {
  cat > "$1" <<EOF
{
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "${PREFIX}ynab_list_*",
      "mcp__plugin_workbench-bujo_scribe__bujo_read",
      {"malformed": "not a permission string"},
      "${PREFIX}ynab_get_*",
      "${PREFIX}ynab_update_transaction",
      "Read(//tmp/**)"
    ],
    "deny": ["Bash(rm:*)"]
  },
  "env": {"FOO": "bar"}
}
EOF
}

# run_step4 <setup-fn> [prelude] [block] — build a sandbox HOME, let <setup-fn>
# shape it (it receives the settings path), then execute the Step 4 block. Real
# jq unless the setup function put a stub earlier on PATH. Sets S4_SETTINGS to
# the file path so assertions can read it back after the sandbox call.
#
# [prelude] is shell prepended to the block, used to pin an ambient `umask` for
# the mode-preservation cases below. [block] replaces the extracted block, used
# by the creation-time mutation test.
run_step4() {
  local setup="$1" prelude="${2:-}" sb
  local block="${3:-$(fenced_block "$CMD" '## Step 4 ' bash)}"
  sb="$(mktemp -d)"
  mkdir -p "$sb/home/.claude" "$sb/bin"
  S4_SETTINGS="$sb/home/.claude/settings.json"
  "$setup" "$S4_SETTINGS" "$sb/bin"
  run_block "$sb/home" "$prelude
$block" PATH="$sb/bin:$PATH"
  S4_AFTER="$(cat "$S4_SETTINGS" 2>/dev/null || true)"
  S4_TMP_LEFT=0
  [ -e "$S4_SETTINGS.tmp" ] && S4_TMP_LEFT=1
  S4_SANDBOX="$sb"
}

# run_doc_step4 <setup-fn> [prelude] — the same harness for the BY-HAND mirror
# in docs/uninstall.md: the doc's own Constants block plus its step-4 fenced
# block, so the checklist a user actually copies is executed, not just grepped.
# Sets the same S4_* variables.
run_doc_step4() {
  local setup="$1" prelude="${2:-}" sb
  local block="${3:-$(fenced_block "$DOC" '## 4. ' bash)}"
  sb="$(mktemp -d)"
  mkdir -p "$sb/home/.claude" "$sb/bin"
  S4_SETTINGS="$sb/home/.claude/settings.json"
  "$setup" "$S4_SETTINGS" "$sb/bin"
  local errf; errf="$(mktemp)"
  set +e
  B_OUT="$(env HOME="$sb/home" PATH="$sb/bin:$PATH" "${BASH:-/bin/bash}" -c "$(doc_constants_block)
$prelude
$block" 2>"$errf")"
  set -e
  B_ERR="$(cat "$errf")"; rm -f "$errf"
  S4_AFTER="$(cat "$S4_SETTINGS" 2>/dev/null || true)"
  S4_TMP_LEFT=0
  [ -e "$S4_SETTINGS.tmp" ] && S4_TMP_LEFT=1
  S4_SANDBOX="$sb"
}

_s4_no_file()   { rm -f "$1"; }
_s4_bad_json()  { printf '{ "permissions": { "allow": [ \n' > "$1"; }
_s4_no_match()  { printf '{"permissions":{"allow":["Bash(git status:*)"]}}\n' > "$1"; }
_s4_matches()   { write_settings "$1"; }
_s4_blocked_tmp() { write_settings "$1"; mkdir -p "$1.tmp"; }   # `>` cannot open a dir
_s4_bad_rewrite() {
  write_settings "$1"
  # A jq shim that passes everything through to the real jq EXCEPT the rewrite
  # filter (recognised by its `|=` update), for which it emits truncated,
  # unparseable JSON and exits 0. That makes the staged .tmp genuinely invalid,
  # so the validity gate — not the exit-code gate — is what must catch it.
  cat > "$2/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *'|='*) printf '{"permissions": {"allow": [' ; exit 0 ;;
  esac
done
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "$2/jq"
}

# No settings.json at all — idempotent skip, nothing created.
test_settings_absent_file_skips() {
  run_step4 _s4_no_file
  assert_contains "$B_OUT" "glob not present" "reports the idempotent skip"
  [ ! -f "$S4_SETTINGS" ] || fail "the step created a settings.json that did not exist"
  rm -rf "$S4_SANDBOX"
}

# Unparseable settings.json — fail closed: reported, and left byte-identical.
test_settings_unparseable_is_refused_and_left_untouched() {
  local before
  run_step4 _s4_bad_json
  before='{ "permissions": { "allow": [ '
  assert_contains "$B_ERR" "not valid JSON" "the unparseable file is reported"
  assert_contains "$B_ERR" "by hand" "the removal is handed back to the user"
  assert_eq "$before" "$(printf '%s' "$S4_AFTER" | tr -d '\n')" \
    "an unparseable settings.json must be left byte-for-byte untouched"
  rm -rf "$S4_SANDBOX"
}

# Valid file with zero matching entries — idempotent skip, file unchanged.
test_settings_no_matching_entries_skips() {
  run_step4 _s4_no_match
  assert_contains "$B_OUT" "glob not present — skipping" "reports the idempotent skip"
  assert_contains "$B_OUT" "already clean" "names it as already clean"
  assert_eq '{"permissions":{"allow":["Bash(git status:*)"]}}' \
    "$(printf '%s' "$S4_AFTER" | tr -d '\n')" \
    "a settings.json with no matching entries must be left untouched"
  rm -rf "$S4_SANDBOX"
}

# The real removal: every prefixed entry goes, every sibling entry, the deny
# list, and the unrelated top-level keys all survive. This is the assertion
# that a non-surgical filter (a whole-array replace, a `del(.permissions)`, a
# substring match) fails.
test_settings_removal_is_surgical() {
  run_step4 _s4_matches
  assert_contains "$B_OUT" "Removed 3 workbench-ynab pre-approval entries" \
    "reports the exact count removed"
  assert_json_valid "$S4_SETTINGS"

  local allow; allow="$(jq -r '.permissions.allow[] | select(type == "string")' "$S4_SETTINGS")"
  assert_exact_line "$allow" "Bash(git status:*)"     "an unrelated Bash permission survives"
  assert_exact_line "$allow" "Read(//tmp/**)"          "an unrelated Read permission survives"
  assert_exact_line "$allow" "mcp__plugin_workbench-bujo_scribe__bujo_read" \
    "a sibling plugin's MCP tool survives"
  # The non-string element survives untouched: dropping the `type == "string"`
  # test makes jq error on it, so the removal aborts and settings.json keeps
  # all three workbench-ynab entries instead.
  assert_eq "not a permission string" \
    "$(jq -r '[.permissions.allow[] | select(type == "object")][0].malformed' "$S4_SETTINGS")" \
    "a non-string allow element survives the filter untouched"
  assert_eq "4" "$(jq '.permissions.allow | length' "$S4_SETTINGS")" \
    "exactly the four non-workbench-ynab elements remain"
  assert_eq "0" "$(jq --arg p "$PREFIX" \
    '[.permissions.allow[] | select(type == "string" and startswith($p))] | length' "$S4_SETTINGS")" \
    "no entry carrying the plugin prefix remains"

  # Untouched neighbours outside permissions.allow.
  assert_eq "opus"        "$(jq -r '.model' "$S4_SETTINGS")"           "unrelated top-level key survives"
  assert_eq "bar"         "$(jq -r '.env.FOO' "$S4_SETTINGS")"         "unrelated env block survives"
  assert_eq "Bash(rm:*)"  "$(jq -r '.permissions.deny[0]' "$S4_SETTINGS")" "the deny list survives"
  assert_eq "0" "$S4_TMP_LEFT" "the staged .tmp is not left behind on success"
  rm -rf "$S4_SANDBOX"
}

# The rewrite cannot be staged at all (its `>` target is unopenable) — fail
# closed: reported, original byte-identical.
test_settings_staging_failure_leaves_file_untouched() {
  local expected; expected="$(mktemp)"; write_settings "$expected"
  run_step4 _s4_blocked_tmp
  assert_contains "$B_ERR" "jq rewrite failed" "the staging failure is reported"
  assert_contains "$B_ERR" "left untouched" "the report says the original was not modified"
  assert_eq "$(cat "$expected")" "$S4_AFTER" \
    "a failed rewrite must leave settings.json byte-for-byte untouched"
  rm -f "$expected"; rm -rf "$S4_SANDBOX"
}

# The rewrite "succeeds" but stages invalid JSON — the validity gate, not the
# exit-code gate, is what must catch it. Without the second gate the truncated
# file would be published over the user's real settings.
test_settings_invalid_staged_json_is_rejected() {
  local expected; expected="$(mktemp)"; write_settings "$expected"
  run_step4 _s4_bad_rewrite
  assert_contains "$B_ERR" "invalid JSON" "the invalid staged file is reported"
  assert_contains "$B_ERR" "left untouched" "the report says the original was not modified"
  assert_eq "$(cat "$expected")" "$S4_AFTER" \
    "an invalid staged rewrite must leave settings.json byte-for-byte untouched"
  assert_eq "0" "$S4_TMP_LEFT" "the invalid staged .tmp is cleaned up, not left beside the real file"
  rm -f "$expected"; rm -rf "$S4_SANDBOX"
}

# ---------------------------------------------------------------------------
# AC #4 (issue #280) — the rewrite must not reset settings.json's mode
# ---------------------------------------------------------------------------
# `mv` on one filesystem is a rename(2): the destination inode is replaced
# outright, so the published file carries the STAGED file's mode. Staging under
# the ambient umask therefore reset a settings.json the user had hardened to
# 0600 back to the umask default. Every case below pins `umask 022` as the
# ambient mask — that is what makes the assertions discriminating, since an
# unhardened `jq > tmp; mv` publishes 0644 there regardless of the original.

# A settings.json with a loose mode keeps it: the plugin preserves the user's
# choice on a file it does not own (settings.json is Claude Code's own shared
# config, outside SECURITY.md's plugin-owned artifact inventory) rather than
# imposing one. This is the assertion the mode-restoring `chmod` owns — drop it
# and the `umask 077` staging subshell publishes 0600 instead.
_s4_matches_644() { write_settings "$1"; chmod 644 "$1"; }
_s4_matches_600() { write_settings "$1"; chmod 600 "$1"; }

# settings.json as a SYMLINK to a hardened file — the dotfiles-manager shape
# (chezmoi, Stow, dotbot). The target is kept outside .claude/ so nothing else in
# the sandbox can find it by accident.
_s4_matches_600_symlink() {
  local target; target="$(dirname "$1")/../settings.dotfiles.json"
  write_settings "$target"
  chmod 600 "$target"
  ln -s "$target" "$1"
}

test_settings_loose_mode_is_preserved() {
  run_step4 _s4_matches_644 'umask 022'
  assert_contains "$B_OUT" "Removed 3 workbench-ynab pre-approval entries" \
    "the removal still runs over a 0644 settings.json"
  assert_eq "644" "$(mode_of "$S4_SETTINGS")" \
    "the user's chosen 0644 survives the rewrite"
  rm -rf "$S4_SANDBOX"
}

# Issue #280 core: a settings.json the user hardened to 0600 is STILL 0600
# afterwards. Under the pinned `umask 022` the pre-fix code published 0644 here
# — the exact permission regression this test exists to catch.
test_settings_hardened_mode_is_preserved() {
  run_step4 _s4_matches_600 'umask 022'
  assert_contains "$B_OUT" "Removed 3 workbench-ynab pre-approval entries" \
    "the removal still runs over a 0600 settings.json"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" \
    "a settings.json hardened to 0600 is not widened by the rewrite"
  rm -rf "$S4_SANDBOX"
}

# The mode is read THROUGH the symlink. `stat` without `-L` reports the link's
# own mode (0755 on macOS, a fixed 0777 on GNU regardless of the target), which
# the chmod would then publish — widening a target hardened to 0600 while
# reporting success. The precondition asserts the link's own mode is not 0600, so
# the test cannot pass by coincidence: that is the value a non-dereferencing read
# would capture.
test_settings_symlinked_mode_is_read_through_the_link() {
  run_step4 _s4_matches_600_symlink 'umask 022'
  assert_contains "$B_OUT" "Removed 3 workbench-ynab pre-approval entries" \
    "the removal still runs over a symlinked settings.json"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" \
    "the symlink's target mode is preserved, not the link's own"
  rm -rf "$S4_SANDBOX"
}

# The precondition above, as its own guard: a link whose own mode already equals
# the target's would make that assertion vacuous on this platform.
test_symlink_fixture_can_discriminate() {
  local sb; sb="$(mktemp -d)"
  mkdir -p "$sb/.claude"
  _s4_matches_600_symlink "$sb/.claude/settings.json"
  [ -L "$sb/.claude/settings.json" ] || fail "the fixture must make settings.json a symlink"
  assert_eq "600" "$(mode_of "$sb/settings.dotfiles.json")" "the target is hardened to 0600"
  # `mode_of` is an lstat read, so on the link it reports the link's own mode.
  [ "$(mode_of "$sb/.claude/settings.json")" != "600" ] || \
    fail "the link's own mode matches the target's — the symlink tests could not discriminate"
  rm -rf "$sb"
}

# The staged .tmp is owner-only AT CREATION, not by a later chmod — so the
# pending rewrite never sits world-readable beside the real file. The end-state
# tests above cannot tell WHICH layer set the mode, so neutralize the
# mode-restoring chmod (rewrite it to a `:` no-op, keeping the surrounding
# fail-closed `elif` intact) over a 0644 original under `umask 022`: if the jq
# `>` were staging at the ambient umask the published file would be 0644, so
# only the `( umask 077; … )` subshell can make it 0600.
#
# This is the standing mutation test for the creation-time guarantee: deleting
# `umask 077` from the staging subshell reddens THIS test while the two above
# stay green (the chmod still covers them).
test_settings_staged_tmp_is_owner_only_at_creation() {
  local block
  # The sed script and the case pattern are LITERAL command source text to match
  # — the `$SETTINGS_MODE` in each is the command's own shell, never an
  # expansion here — so SC2016 is a false positive on both.
  # shellcheck disable=SC2016
  block="$(fenced_block "$CMD" '## Step 4 ' bash | sed 's/chmod "$SETTINGS_MODE" /: /')"
  # The sed must actually have found its target — otherwise this test silently
  # degrades into a duplicate of the one above and proves nothing.
  # shellcheck disable=SC2016
  case "$block" in
    *'chmod "$SETTINGS_MODE" '*) fail "the chmod-neutralizing sed did not fire — test would be vacuous" ;;
  esac
  run_step4 _s4_matches_644 'umask 022' "$block"
  assert_contains "$B_OUT" "Removed 3 workbench-ynab pre-approval entries" \
    "the removal still runs with the chmod neutralized"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" \
    "the staged .tmp was born 0600 — the umask 077 subshell, not the chmod"
  rm -rf "$S4_SANDBOX"
}

# Fail closed when the mode cannot be READ: publishing the rewrite would reset
# the mode to the ambient umask, so the step refuses, reports, and hands the
# removal back to the user. `stat` is stubbed to fail both ways — the only way
# to reach that branch.
_s4_no_stat() {
  write_settings "$1"; chmod 600 "$1"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$2/stat"
  chmod +x "$2/stat"
}

test_settings_unreadable_mode_fails_closed() {
  local expected; expected="$(mktemp)"; write_settings "$expected"
  run_step4 _s4_no_stat 'umask 022'
  assert_contains "$B_ERR" "Could not read the permission mode" \
    "the unreadable mode is reported"
  assert_contains "$B_ERR" "by hand" "the removal is handed back to the user"
  assert_eq "$(cat "$expected")" "$S4_AFTER" \
    "an unreadable mode must leave settings.json byte-for-byte untouched"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" "the original mode is left alone"
  assert_eq "0" "$S4_TMP_LEFT" "no stale .tmp is left beside the real file"
  rm -f "$expected"; rm -rf "$S4_SANDBOX"
}

# Fail closed when the mode cannot be RE-APPLIED to the staged file: the .tmp is
# dropped and the real file is untouched, rather than published at the umask's
# mode. `chmod` is stubbed to fail; nothing else in the block calls it.
_s4_no_chmod() {
  write_settings "$1"; chmod 600 "$1"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$2/chmod"
  command chmod +x "$2/chmod"
}

test_settings_failed_mode_restore_fails_closed() {
  local expected; expected="$(mktemp)"; write_settings "$expected"
  run_step4 _s4_no_chmod 'umask 022'
  assert_contains "$B_ERR" "Could not restore mode" "the failed mode restore is reported"
  assert_contains "$B_ERR" "left untouched" "the report says the original was not modified"
  assert_eq "$(cat "$expected")" "$S4_AFTER" \
    "a failed mode restore must leave settings.json byte-for-byte untouched"
  assert_eq "0" "$S4_TMP_LEFT" "the staged .tmp is cleaned up, not left beside the real file"
  rm -f "$expected"; rm -rf "$S4_SANDBOX"
}

# ---------------------------------------------------------------------------
# AC #4 (issue #280) — the BY-HAND mirror in docs/uninstall.md, executed
# ---------------------------------------------------------------------------
# The checklist is what a user copy-pastes once the plugin is gone, so it needs
# the same guarantee — and proving it by grep would be hollow. These execute the
# doc's own step-4 block against the doc's own Constants.

test_manual_step4_removal_works_and_preserves_a_loose_mode() {
  run_doc_step4 _s4_matches_644 'umask 022'
  assert_json_valid "$S4_SETTINGS"
  assert_eq "0" "$(jq --arg p "$PREFIX" \
    '[.permissions.allow[] | select(type == "string" and startswith($p))] | length' "$S4_SETTINGS")" \
    "the by-hand block removes every prefixed entry"
  assert_eq "4" "$(jq '.permissions.allow | length' "$S4_SETTINGS")" \
    "the by-hand block leaves every other element alone"
  assert_eq "644" "$(mode_of "$S4_SETTINGS")" \
    "the by-hand block preserves the user's chosen 0644"
  assert_eq "0" "$S4_TMP_LEFT" "the by-hand block leaves no stale .tmp"
  rm -rf "$S4_SANDBOX"
}

test_manual_step4_preserves_a_hardened_mode() {
  run_doc_step4 _s4_matches_600 'umask 022'
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" \
    "the by-hand block does not widen a settings.json hardened to 0600"
  rm -rf "$S4_SANDBOX"
}

# The by-hand chain's staged .tmp is owner-only AT CREATION too — the same
# mutation as the command's, so the doc's `umask 077` link is pinned by its own
# assertion rather than riding on the command's. Neutralize the mode-restoring
# `chmod` link (to a `:` no-op, which keeps the `&&` chain intact) over a 0644
# original under `umask 022`: only the `( umask 077; … )` subshell can make the
# published file 0600 from there.
test_manual_step4_staged_tmp_is_owner_only_at_creation() {
  local block
  # Literal doc source text on both lines — SC2016 is a false positive.
  # shellcheck disable=SC2016
  block="$(fenced_block "$DOC" '## 4. ' bash | sed 's/chmod "$SETTINGS_MODE" /: /')"
  # shellcheck disable=SC2016
  case "$block" in
    *'chmod "$SETTINGS_MODE" '*) fail "the chmod-neutralizing sed did not fire — test would be vacuous" ;;
  esac
  run_doc_step4 _s4_matches_644 'umask 022' "$block"
  assert_json_valid "$S4_SETTINGS"
  assert_eq "0" "$(jq --arg p "$PREFIX" \
    '[.permissions.allow[] | select(type == "string" and startswith($p))] | length' "$S4_SETTINGS")" \
    "the removal still runs with the chmod link neutralized"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" \
    "the by-hand block's staged .tmp was born 0600 — the umask 077 subshell, not the chmod"
  rm -rf "$S4_SANDBOX"
}

# The by-hand chain fails closed when the mode cannot be read: no rewrite is
# attempted, the file is untouched, and the failure is reported.
test_manual_step4_unreadable_mode_fails_closed() {
  local expected; expected="$(mktemp)"; write_settings "$expected"
  run_doc_step4 _s4_no_stat 'umask 022'
  assert_contains "$B_OUT" "left untouched" "the by-hand chain reports the refusal"
  assert_eq "$(cat "$expected")" "$S4_AFTER" \
    "the by-hand chain leaves settings.json byte-for-byte untouched"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" "the original mode is left alone"
  assert_eq "0" "$S4_TMP_LEFT" "no stale .tmp is left beside the real file"
  rm -f "$expected"; rm -rf "$S4_SANDBOX"
}

# The by-hand chain reads the mode through a symlink too — the command site's
# `-L` is no use to a user copy-pasting the doc's own chain.
test_manual_step4_reads_the_mode_through_a_symlink() {
  run_doc_step4 _s4_matches_600_symlink 'umask 022'
  assert_json_valid "$S4_SETTINGS"
  assert_eq "0" "$(jq --arg p "$PREFIX" \
    '[.permissions.allow[] | select(type == "string" and startswith($p))] | length' "$S4_SETTINGS")" \
    "the by-hand block still removes every prefixed entry over a symlink"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" \
    "the by-hand block preserves the symlink TARGET's mode, not the link's own"
  rm -rf "$S4_SANDBOX"
}

# The two remaining links in the by-hand `&&` chain, EXECUTED rather than
# string-matched. Their command-site mirrors are covered by
# test_settings_invalid_staged_json_is_rejected and
# test_settings_failed_mode_restore_fails_closed; the doc had only grep-level
# proof, which cannot catch a broken `&&`/`||` short-circuit that leaves the
# predicate text intact.

# The rewrite "succeeds" but stages invalid JSON — the `jq -e .` link, not the
# exit status of the rewrite, is what must stop the swap.
test_manual_step4_invalid_staged_json_is_rejected() {
  local expected; expected="$(mktemp)"; write_settings "$expected"
  run_doc_step4 _s4_bad_rewrite 'umask 022'
  assert_contains "$B_OUT" "left untouched" "the by-hand chain reports the refusal"
  assert_eq "$(cat "$expected")" "$S4_AFTER" \
    "an invalid staged rewrite must leave settings.json byte-for-byte untouched"
  assert_eq "0" "$S4_TMP_LEFT" "the invalid staged .tmp is cleaned up, not left beside the real file"
  rm -f "$expected"; rm -rf "$S4_SANDBOX"
}

# The mode cannot be re-applied to the staged file — the `chmod` link must break
# the chain rather than let the swap publish at the umask's mode.
test_manual_step4_failed_mode_restore_fails_closed() {
  local expected; expected="$(mktemp)"; write_settings "$expected"
  run_doc_step4 _s4_no_chmod 'umask 022'
  assert_contains "$B_OUT" "left untouched" "the by-hand chain reports the refusal"
  assert_eq "$(cat "$expected")" "$S4_AFTER" \
    "a failed mode restore must leave settings.json byte-for-byte untouched"
  assert_eq "600" "$(mode_of "$S4_SETTINGS")" "the original mode is left alone"
  assert_eq "0" "$S4_TMP_LEFT" "the staged .tmp is cleaned up, not left beside the real file"
  rm -f "$expected"; rm -rf "$S4_SANDBOX"
}

# ---------------------------------------------------------------------------
# AC #5 / #6 — the data directory: prompt content, then all four branches
# ---------------------------------------------------------------------------

# The prompt is scoped to Step 5's ```jsonc fence, so the surrounding rationale
# prose — which necessarily discusses the same record classes — cannot satisfy
# these checks. Deleting the fence empties the extraction and fails them all.
test_data_dir_prompt_names_every_record_class_and_warns() {
  local q; q="$(fenced_block "$CMD" '## Step 5 ' jsonc)"
  [ -n "$q" ] || fail "Step 5 has no AskUserQuestion jsonc block"
  assert_contains "$q" "AskUserQuestion" "the data-dir decision is an AskUserQuestion prompt"
  assert_contains "$q" "workbench-ynab-claude-workbench" "the prompt names the data directory path"
  # Each plaintext financial record class the AC requires be named explicitly,
  # matched on its full PATH PATTERN rather than a bare word: the prompt's own
  # warning prose independently says "audit trail", so a bare `audit` needle
  # stayed green with the audit-log entry deleted from the record list.
  local f
  for f in "config.json" "audit/audit-<YYYY-MM>.jsonl" "proposals/" \
           "monitor-state.json" "alert-log.jsonl" "tax-profile.json" "tax-tracker.json"; do
    assert_contains "$q" "$f" "the prompt names the $f record class"
  done
  assert_contains "$q" "UNENCRYPTED" "the prompt states the records are unencrypted"
  assert_contains "$q" "plaintext financial records" "the prompt says what the records are"
  assert_contains "$q" "IRREVERSIBLE" "the prompt warns the deletion cannot be undone"
}

# The default is Keep: it is the FIRST option and is labelled as recommended,
# and only an explicit choice selects deletion. Checked against the options
# array, not the prose, so a reordering that makes Delete the default fails.
test_data_dir_default_answer_is_keep() {
  local q labels first
  q="$(fenced_block "$CMD" '## Step 5 ' jsonc)"
  labels="$(printf '%s\n' "$q" | grep -o '{ label: "[^"]*"' | sed 's/.*label: "//; s/"$//')"
  first="$(printf '%s\n' "$labels" | head -n 1)"
  case "$first" in
    Keep*) : ;;
    *) fail "the first (default) data-dir option is [$first], not Keep" ;;
  esac
  assert_contains "$first" "recommended" "the Keep option is marked as the recommendation"
  local body; body="$(section_body "$CMD" '## Step 5 ')"
  assert_contains "$body" "Only an explicit choice" \
    "Step 5 states that only an explicit choice selects deletion"
}

# run_step5 <mode> — execute Step 5's block. `guard` runs the absent-directory
# guard (block 1); `keep` / `delete` / `blocked` run the decision block
# (block 2) with DATA_CHOICE set. Sets S5_DIR / S5_FILE.
run_step5() {
  local mode="$1" sb; sb="$(mktemp -d)"
  mkdir -p "$sb/home"
  S5_DIR="$sb/home/.claude/plugins/data/workbench-ynab-claude-workbench"
  S5_FILE="$S5_DIR/config.json"
  local which=2 choice=keep
  case "$mode" in
    guard)   which=1 ;;
    keep)    mkdir -p "$S5_DIR"; printf '{}\n' > "$S5_FILE" ;;
    delete)  mkdir -p "$S5_DIR"; printf '{}\n' > "$S5_FILE"; choice=delete ;;
    blocked) mkdir -p "$S5_DIR"; printf '{}\n' > "$S5_FILE"; choice=delete
             chmod 500 "$(dirname "$S5_DIR")" ;;   # rm cannot unlink from a read-only parent
    *) fail "unknown run_step5 mode: $mode" ;;
  esac
  run_block "$sb/home" "DATA_CHOICE=$choice
$(fenced_block "$CMD" '## Step 5 ' bash "$which")"
  chmod 700 "$(dirname "$S5_DIR")" 2>/dev/null || true
  S5_SANDBOX="$sb"
}

# Directory already gone — idempotent skip, no prompt needed.
test_data_dir_absent_skips() {
  run_step5 guard
  assert_contains "$B_OUT" "Data directory not present" "reports the absent directory"
  assert_contains "$B_OUT" "already clean" "names it as already clean"
  rm -rf "$S5_SANDBOX"
}

# Keep — the AC's default outcome: the path is printed and NO file is touched.
test_data_dir_keep_touches_nothing() {
  run_step5 keep
  assert_contains "$B_OUT" "Kept" "reports that the directory was kept"
  assert_contains "$B_OUT" "workbench-ynab-claude-workbench" "prints the kept directory path"
  assert_contains "$B_OUT" "no files were touched" "states that nothing was touched"
  assert_dir_exists "$S5_DIR"
  assert_file_exists "$S5_FILE"
  rm -rf "$S5_SANDBOX"
}

# Delete — the directory is removed in full and the removal is confirmed.
test_data_dir_delete_removes_in_full() {
  run_step5 delete
  assert_contains "$B_OUT" "Deleted" "confirms the deletion"
  [ ! -d "$S5_DIR" ] || fail "the data directory still exists after the delete branch"
  rm -rf "$S5_SANDBOX"
}

# Delete that cannot complete — the post-rm re-check is what catches it.
# `rm -rf` exits 0 on a directory it could not clear, so an implementation that
# keyed the success message off rm's exit status would print "Deleted" here
# while every financial record was still on disk.
test_data_dir_partial_delete_is_reported_not_claimed_deleted() {
  if [ "$(id -u)" -eq 0 ]; then
    printf '  (skipped: running as root — a read-only parent would not block rm)\n'
    return 0
  fi
  run_step5 blocked
  assert_dir_exists "$S5_DIR"
  assert_contains "$B_ERR" "Could not fully remove" "the partial delete is reported on stderr"
  assert_contains "$B_ERR" "by hand" "the user is told to finish it by hand"
  case "$B_OUT" in
    *"✅ Deleted"*) fail "a partial delete was reported as a successful deletion" ;;
  esac
  rm -rf "$S5_SANDBOX"
}

# ---------------------------------------------------------------------------
# AC #2 — scheduled tasks
# ---------------------------------------------------------------------------
# Scoped to Step 2's body: the two ids also appear in the overview table and the
# summary block, so a whole-file check would pass with this step deleted.
test_step2_removes_both_task_ids_and_only_those() {
  local body; body="$(section_body "$CMD" '## Step 2 ')"
  [ -n "$body" ] || fail "Step 2 is missing"
  assert_contains "$body" "delete_scheduled_task" "Step 2 calls the delete tool"
  assert_contains "$body" "taskId: ynab-review"  "Step 2 removes the review task"
  assert_contains "$body" "taskId: ynab-monitor" "Step 2 removes the monitor task"
  assert_contains "$body" "no scheduled tasks found — skipping" \
    "Step 2 logs the AC's exact idempotent skip line when neither task exists"
  assert_contains "$body" "never claim" \
    "Step 2 forbids reporting a removal that did not happen"
  # The legacy prototype ids belong to /ynab-migrate — named here only as
  # explicitly out of scope.
  assert_contains "$body" "ynab-migrate" "Step 2 defers the prototype task ids to ynab-migrate"
}

# An unreachable scheduled-tasks MCP must not abort the teardown — the Keychain,
# settings, and data-dir steps still run. Scoped to Step 1, which owns the probe.
test_unreachable_scheduler_does_not_abort_the_teardown() {
  local body; body="$(section_body "$CMD" '## Step 1 ')"
  assert_contains "$body" "not reachable" "Step 1 handles an unreachable scheduled-tasks MCP"
  assert_contains "$body" "continue" "Step 1 continues the teardown when it is unreachable"
}

# ---------------------------------------------------------------------------
# AC #7 — the token-revocation reminder
# ---------------------------------------------------------------------------
# Scoped to Step 6's fenced block — the literal text printed to the user — not
# the section prose that introduces it.
test_revocation_reminder_is_prominent_and_explicit() {
  local block; block="$(fenced_block "$CMD" '## Step 6 ' text)"
  [ -n "$block" ] || fail "Step 6 has no fenced reminder block"
  assert_contains "$block" "REVOKE YOUR YNAB TOKEN" "the reminder headlines the revocation"
  assert_contains "$block" "MANUAL STEP" "the reminder marks it as manual"
  assert_contains "$block" "does NOT revoke it at YNAB" \
    "the reminder states that deleting the Keychain entry does not revoke server-side access"
  assert_contains "$block" "https://app.ynab.com/settings/developer" "the reminder links the YNAB developer settings"
  assert_contains "$block" "Account Settings" "the reminder names the Account Settings path"
  assert_contains "$block" "Developer Settings" "the reminder names the Developer Settings path"
  local body; body="$(section_body "$CMD" '## Step 6 ')"
  assert_contains "$body" "verbatim" "Step 6 requires the block be printed verbatim"
  assert_contains "$body" "whatever happened in Step 3" \
    "the reminder prints regardless of the Keychain step's outcome"
}

# ---------------------------------------------------------------------------
# AC #8 — the teardown summary
# ---------------------------------------------------------------------------
# Scoped to Step 7's fenced summary block: every component gets a line, and all
# four outcome classes (removed / not-found / kept / manual) are represented.
test_summary_lists_every_component_and_outcome_class() {
  local block; block="$(fenced_block "$CMD" '## Step 7 ' text)"
  [ -n "$block" ] || fail "Step 7 has no fenced summary block"
  local c
  for c in "ynab-review" "ynab-monitor" "Keychain" "settings.json" "Data directory" "Report directory"; do
    assert_contains "$block" "$c" "the summary has a line for $c"
  done
  assert_contains "$block" "removed"          "the summary reports the removed outcome"
  assert_contains "$block" "not found"        "the summary reports the not-found/skipped outcome"
  assert_contains "$block" "KEPT"             "the summary reports the deliberately-kept outcome"
  assert_contains "$block" "Manual steps remaining" "the summary lists remaining manual steps"
  assert_contains "$block" "Revoke the YNAB token" "the summary always carries the revocation step"
  assert_contains "$block" "idempotent"       "the summary states the command is safe to re-run"
}

# AC #9 (command half): every step is stated to be independently idempotent and
# a re-run after a partial teardown reports already-clean rather than erroring.
test_command_states_the_idempotency_contract() {
  local head; head="$(awk '/^## Constants/{exit} {print}' "$CMD")"
  assert_contains "$head" "independently idempotent" \
    "the command opens with the per-step idempotency contract"
  assert_contains "$head" "already clean" "it names the already-clean report"
  assert_contains "$head" "never errors" "it states a re-run never errors"
  assert_contains "$head" "No step aborts the run" \
    "it states a missing component never aborts the remaining steps"
}

# ---------------------------------------------------------------------------
# AC #9 — docs/uninstall.md mirrors every automated step
# ---------------------------------------------------------------------------

test_manual_checklist_exists_and_covers_every_step() {
  assert_file_exists "$DOC"
  local list; list="$(section_body "$DOC" '## Checklist')"
  [ -n "$list" ] || fail "docs/uninstall.md has no '## Checklist' section"
  # One checklist entry per automated component, plus the two steps no command
  # can perform (revoke, remove the plugin).
  local item
  for item in "scheduled tasks" "Keychain" "pre-approval entries" "data directory" "Revoke" "plugin itself"; do
    assert_contains "$list" "$item" "the checklist covers: $item"
  done
  assert_eq "7" "$(printf '%s\n' "$list" | grep -c '^- \[ \]')" \
    "the checklist has one unchecked entry per teardown step"
}

# The by-hand steps must be the SAME operations, not a vague summary: each
# section carries the real command. Scoped per section so one section's command
# cannot satisfy another's check.
test_manual_checklist_carries_the_real_commands() {
  # The single-quoted needles below are LITERAL checklist text to find — the
  # `$KEYCHAIN_*` / `$p` / `$SETTINGS` inside them are the doc's own documented
  # shell, never expansions here — so SC2016 is a false positive on each.
  # shellcheck disable=SC2016
  assert_contains "$(section_body "$DOC" '## 3. ')" \
    'security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT"' \
    "checklist step 3 gives the real Keychain removal command"
  local s4; s4="$(section_body "$DOC" '## 4. ')"
  # shellcheck disable=SC2016
  assert_contains "$s4" 'startswith($p)' "checklist step 4 gives the prefix-scoped jq filter"
  assert_contains "$s4" '.permissions.allow |= map(select' "checklist step 4 rewrites only permissions.allow"
  # shellcheck disable=SC2016
  assert_contains "$s4" 'jq -e . "$SETTINGS.tmp"' "checklist step 4 re-validates before replacing the original"
  local s2; s2="$(section_body "$DOC" '## 2. ')"
  assert_contains "$s2" "taskId: ynab-review"  "checklist step 2 names the review task id"
  assert_contains "$s2" "taskId: ynab-monitor" "checklist step 2 names the monitor task id"
  local s6; s6="$(section_body "$DOC" '## 6. ')"
  assert_contains "$s6" "https://app.ynab.com/settings/developer" "checklist step 6 links token revocation"
  assert_contains "$s6" "does **not**" "checklist step 6 states the Keychain delete does not revoke"
}

# The manual checklist's jq filter must be the SAME filter the command executes
# — a checklist that drifts from the command is worse than no checklist. Both
# are extracted from their own files and compared on the filter body.
test_manual_and_command_settings_filters_agree() {
  local cmd_filter doc_filter
  cmd_filter="$(fenced_block "$CMD" '## Step 4 ' bash | grep -F '.permissions.allow |= map(select' | tr -d ' ')"
  doc_filter="$(section_body "$DOC" '## 4. ' | grep -F '.permissions.allow |= map(select' | tr -d ' ')"
  [ -n "$cmd_filter" ] || fail "no permissions.allow filter found in the command's Step 4 block"
  [ -n "$doc_filter" ] || fail "no permissions.allow filter found in the checklist's step 4"
  assert_eq "$cmd_filter" "$doc_filter" \
    "the manual checklist's jq filter must match the command's, character for character"
}

# ---------------------------------------------------------------------------
# AC #10 — consistent with the issue #65 privacy posture
# ---------------------------------------------------------------------------

# The command's data-dir step points at the SECURITY.md inventory (the posture's
# canonical artifact list) and uses its vocabulary, so the two cannot drift into
# describing the same files differently.
test_data_dir_ux_matches_the_privacy_posture() {
  local body; body="$(section_body "$CMD" '## Step 5 ')"
  assert_contains "$body" "SECURITY.md" "Step 5 points at the artifact inventory"
  assert_contains "$body" "Generated Artifacts" "Step 5 names the inventory section"
  assert_contains "$body" "unencrypted, plaintext financial records" \
    "Step 5 uses the posture's own description of the records"
  assert_contains "$body" "audit trail" "Step 5 explains what deleting the directory destroys"
  # Reports live outside the data dir and are the prune tool's business —
  # deleting a user-chosen directory would exceed this command's scope.
  assert_contains "$body" "ynab-prune" "Step 5 routes report cleanup to the prune tool"
  assert_contains "$body" "never deletes it" "Step 5 states the report directory is not deleted"
}

# SECURITY.md's uninstall pointer now names the shipped surfaces instead of
# describing #67 as future work, and matches what the command actually does
# (prompts for the data dir, keeps by default, never deletes reports).
test_security_md_points_at_the_shipped_uninstall() {
  local sec; sec="$(cat "$REPO_ROOT/SECURITY.md")"
  assert_contains "$sec" "/workbench-ynab:uninstall" "SECURITY.md names the uninstall command"
  assert_contains "$sec" "docs/uninstall.md" "SECURITY.md links the by-hand checklist"
  assert_contains "$sec" "keeps it by default" "SECURITY.md records the keep-by-default posture"
  # Every inventory row that makes a claim about uninstall must agree with the
  # keep-by-default posture. Two rows previously read "removed at uninstall"
  # flat — a claim the command does not honour, since it keeps the data
  # directory unless the user explicitly chooses deletion.
  local row
  while IFS= read -r row; do
    case "$row" in
      *"only if you choose to delete"*) : ;;
      *) fail "SECURITY.md inventory row claims unconditional removal at uninstall: $row" ;;
    esac
  done < <(grep -F 'removed at uninstall' "$REPO_ROOT/SECURITY.md")
}

# The README tells a user the teardown exists BEFORE they remove the plugin —
# after removal the command is gone. Scoped to the privacy section.
test_readme_warns_removal_leaves_state_behind() {
  local body; body="$(section_body "$REPO_ROOT/README.md" '## Privacy')"
  assert_contains "$body" "Removing the plugin leaves all of this behind" \
    "the README privacy section warns that removal leaves state behind"
  assert_contains "$body" "/workbench-ynab:uninstall" "it names the uninstall command"
  assert_contains "$body" "docs/uninstall.md" "it links the by-hand checklist"
  assert_contains "$body" "revoke the token" "it repeats the manual revocation step"
}

run_tests
