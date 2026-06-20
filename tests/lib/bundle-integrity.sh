#!/usr/bin/env bash
#
# bundle-integrity.sh — reusable integrity assertions for the vendored YNAB MCP
# bundle (issue #78).
#
# This is the single source of truth for "is the vendored bundle sound?" — both
# the offline-boot test (tests/offline-boot.sh) and the release workflow (M5-5)
# source this file and call bi_assert_integrity, so neither duplicates the
# checksum or boot logic.
#
# It provides two assertions and a combined entry point:
#
#   bi_assert_checksum  <repo_root>  — the committed bundle still matches the
#                                      provenance recorded in vendored.json
#                                      (delegates to vendor/ynab-mcp/verify-bundle.sh,
#                                      the M5-3 checksum record guard).
#   bi_assert_boot      <repo_root>  — the bundle BOOTS offline: pipe a JSON-RPC
#                                      initialize + tools/list handshake to the
#                                      node entrypoint with NO node_modules and a
#                                      fake token, and assert a clean response.
#   bi_assert_integrity <repo_root>  — runs both; the entry point M5-5 invokes.
#
# Sourcing contract: this library does NOT enable `set -e` (it must not change
# the caller's shell flags). Every assertion prints a `✅`/`❌` line and updates
# the BI_PASS / BI_FAIL counters; the combined entry point returns non-zero iff
# any assertion failed, so a release workflow can gate on its exit status.
#
# Style mirrors tests/persona-loader.test.sh and tests/unit/test-config.sh: raw
# bash, no framework, mktemp sandboxes, POSIX-friendly (macOS bash 3.2).

# ---------------------------------------------------------------------------
# Counters + reporting helpers (shared by every assertion below).
# ---------------------------------------------------------------------------
BI_PASS=${BI_PASS:-0}
BI_FAIL=${BI_FAIL:-0}

bi_ok()   { BI_PASS=$((BI_PASS + 1)); printf '  ✅ %s\n' "$1"; }
bi_bad()  { BI_FAIL=$((BI_FAIL + 1)); printf '  ❌ %s\n' "$1"; }

# bi_assert <desc> <status> — bump pass/fail from a command's exit status.
bi_assert() {
  if [ "$2" -eq 0 ]; then bi_ok "$1"; else bi_bad "$1"; fi
}

# The raw tool names the vendored bundle (@dizzlkheinz/ynab-mcpb) must expose,
# per issue #78's acceptance criteria. These are the names `tools/list` returns
# BEFORE the Claude harness adds its `mcp__plugin_workbench-ynab_ynab__` prefix.
# Newline-separated (one per line) so coverage checks never depend on shell
# word-splitting / the ambient IFS.
BI_REQUIRED_TOOLS="ynab_list_budgets
ynab_list_accounts
ynab_list_categories
ynab_list_transactions
ynab_list_payees
ynab_get_month
ynab_update_transaction
ynab_update_transactions
ynab_update_category
ynab_create_transaction
ynab_create_transactions
ynab_delete_transaction
ynab_reconcile_account
ynab_export_transactions"

# A deliberately fake, non-empty token. The bundle's config schema requires
# YNAB_ACCESS_TOKEN to be a non-empty string at startup, but only sends it to
# YNAB when a *tool* is invoked — so the initialize + tools/list handshake never
# touches the network and never needs a real token. Never the real one.
#
# WARNING: YNAB_ACCESS_TOKEN_TEST is an override for the fake token ONLY — it must
# NEVER hold a real YNAB PAT. Its name sits in the YNAB_ACCESS_TOKEN namespace, so
# a careless copy-paste of the real var into a CI env would feed a live PAT into the
# boot. The boot is hermetic (no network on initialize/tools-list), so the blast
# radius is small, but keep a fake value here regardless.
BI_FAKE_TOKEN="${YNAB_ACCESS_TOKEN_TEST:-fake-offline-boot-token-not-a-real-pat}"

# ---------------------------------------------------------------------------
# Checksum assertion — delegates to the existing M5-3 guard.
# ---------------------------------------------------------------------------
# bi_assert_checksum <repo_root>
#   Re-uses vendor/ynab-mcp/verify-bundle.sh, which asserts the bundle's SHA-256
#   matches vendored.json's recorded bundle_sha256 (plus marker/bundle/shim
#   presence and shim executability). A mismatch fails with a clear message —
#   verify-bundle.sh prints the recorded vs. actual hashes on drift.
bi_assert_checksum() {
  local repo_root="$1"
  local verify="$repo_root/vendor/ynab-mcp/verify-bundle.sh"
  local out

  if [ ! -f "$verify" ]; then
    bi_bad "bundle checksum: verify-bundle.sh missing at $verify"
    return 1
  fi

  if out="$(bash "$verify" 2>&1)"; then
    bi_ok "bundle SHA-256 matches the committed vendored.json record"
    return 0
  fi

  bi_bad "bundle checksum drift — vendored.json no longer matches index.cjs"
  printf '%s\n' "$out" | sed 's/^/       /'
  return 1
}

# ---------------------------------------------------------------------------
# Offline-boot assertion — the linchpin.
# ---------------------------------------------------------------------------
# Resolve the node entrypoint that boots the vendored bundle.
#
# Default: bin/ynab-mcp — the frozen node shim that `require()`s the bundle and
# reads YNAB_ACCESS_TOKEN straight from the environment, which is exactly what a
# hermetic fake-token boot needs. (The eventual bin/launcher.sh — M1-5 — reads
# the token from the macOS Keychain, so it can't be driven by a fake env token;
# it is therefore NOT the right target for this offline, hermetic proof.)
#
# Override with YNAB_MCP_ENTRYPOINT to point at a different executable when one
# that honours the env token lands.
bi_resolve_entrypoint() {
  local repo_root="$1"
  printf '%s' "${YNAB_MCP_ENTRYPOINT:-$repo_root/bin/ynab-mcp}"
}

# bi_request <id> <method> [params-json] — emit one newline-free JSON-RPC line.
# The MCP stdio transport is newline-delimited: one JSON object per line.
bi_request() {
  # NB: do NOT fold the default into the parameter expansion — bash 3.2 expands
  # `${3:-{\}}` to the literal string `{\}` (invalid JSON, breaks --argjson), not
  # to `{}`. Default in a separate, unambiguous step.
  local id="$1" method="$2" params="${3:-}"
  [ -z "$params" ] && params='{}'
  if [ "$id" = "-" ]; then
    # a notification: no id, no response expected
    jq -cn --arg m "$method" --argjson p "$params" \
      '{jsonrpc:"2.0", method:$m, params:$p}'
  else
    jq -cn --argjson i "$id" --arg m "$method" --argjson p "$params" \
      '{jsonrpc:"2.0", id:$i, method:$m, params:$p}'
  fi
}

# bi_response_by_id <id> <stdout-file> — echo the first JSON-RPC line whose .id
# matches, tolerating (skipping) any non-JSON line so a stray line never breaks
# extraction. Empty output + non-zero status when not found.
bi_response_by_id() {
  local want="$1" file="$2" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if printf '%s' "$line" | jq -e --argjson w "$want" '.id == $w' >/dev/null 2>&1; then
      printf '%s' "$line"
      return 0
    fi
  done < "$file"
  return 1
}

# bi_assert_boot <repo_root>
#   Drive the offline boot handshake and assert the AC's boot guarantees:
#     * runs with NO node_modules reachable (a clean temp mirror of just the
#       shim + bundle), so dist index.cjs is the only code path exercised;
#     * a fake YNAB_ACCESS_TOKEN — the real token's absence never fails the test;
#     * the process exits 0;
#     * stdout is pure JSON-RPC (every line is a jsonrpc:"2.0" message) — the
#       stderr-vs-stdout gotcha that corrupts an MCP handshake;
#     * the initialize response is parseable JSON with jsonrpc/id/result;
#     * tools/list lists at minimum every BI_REQUIRED_TOOLS name.
bi_assert_boot() {
  local repo_root="$1"

  if ! command -v node >/dev/null 2>&1; then
    bi_bad "offline boot: 'node' not found on PATH — the bundle boots on a \
system node (see README Prerequisites). Cannot prove boot without it."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    bi_bad "offline boot: 'jq' not found on PATH (required to frame/parse JSON-RPC)"
    return 1
  fi

  local entry; entry="$(bi_resolve_entrypoint "$repo_root")"
  if [ ! -e "$entry" ]; then
    bi_bad "offline boot: entrypoint not found: $entry"
    return 1
  fi

  # --- Hermetic, node_modules-free sandbox --------------------------------
  # Mirror ONLY the shim and the vendored bundle into a clean temp tree. mktemp
  # dirs carry no node_modules, so index.cjs is provably the only code path —
  # a stronger guarantee than renaming an in-repo node_modules aside, and it
  # never mutates the working tree. Skipped when YNAB_MCP_ENTRYPOINT overrides
  # the default shim (the caller then owns the entrypoint's environment).
  local sandbox run_entry
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/ynab-offline-boot.XXXXXX")"
  if [ -z "${YNAB_MCP_ENTRYPOINT:-}" ]; then
    mkdir -p "$sandbox/bin" "$sandbox/vendor/ynab-mcp"
    cp "$repo_root/bin/ynab-mcp"              "$sandbox/bin/ynab-mcp"
    cp "$repo_root/vendor/ynab-mcp/index.cjs" "$sandbox/vendor/ynab-mcp/index.cjs"
    chmod +x "$sandbox/bin/ynab-mcp"
    run_entry="$sandbox/bin/ynab-mcp"
  else
    run_entry="$entry"
  fi

  local req_file="$sandbox/requests.jsonl"
  local out_file="$sandbox/stdout.log"
  local err_file="$sandbox/stderr.log"

  # initialize → initialized notification → tools/list, one JSON-RPC line each.
  {
    bi_request 1 initialize \
      '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"offline-boot-test","version":"0.0.0"}}'
    bi_request - notifications/initialized '{}'
    bi_request 2 tools/list '{}'
  } > "$req_file"

  # Run the entrypoint with a clean, network-irrelevant env: a fake token and a
  # PATH that still finds node. Feed the requests file as stdin (EOF tells the
  # stdio transport to shut down → the process exits on its own).
  YNAB_ACCESS_TOKEN="$BI_FAKE_TOKEN" "$run_entry" \
    < "$req_file" > "$out_file" 2> "$err_file" &
  local pid=$!

  # Portable timeout (macOS ships no timeout(1)): poll until the process exits,
  # killing it if it overruns — a hang is itself a boot failure.
  local waited=0 timeout="${BI_BOOT_TIMEOUT:-25}" rc
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      bi_bad "offline boot: process did not exit within ${timeout}s after \
stdin EOF (handshake hung)"
      [ -s "$err_file" ] && printf '       stderr: %s\n' "$(head -3 "$err_file")"
      rm -rf "$sandbox"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"; rc=$?

  # --- Assertions ----------------------------------------------------------
  # 1. Clean exit.
  bi_assert "offline boot: entrypoint exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
  if [ "$rc" -ne 0 ] && [ -s "$err_file" ]; then
    printf '       stderr: %s\n' "$(head -3 "$err_file")"
  fi

  # 2. stdout purity: every non-blank line is a jsonrpc:"2.0" message.
  local impure=0 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! printf '%s' "$line" | jq -e '.jsonrpc == "2.0"' >/dev/null 2>&1; then
      impure=$((impure + 1))
      printf '       stray non-JSON-RPC stdout line: %s\n' "$line"
    fi
  done < "$out_file"
  bi_assert "offline boot: stdout carries ONLY JSON-RPC (no launcher chatter)" \
    "$([ "$impure" -eq 0 ] && [ -s "$out_file" ] && echo 0 || echo 1)"

  # 3. initialize response: parseable JSON with jsonrpc, id, and result.
  local init_resp
  init_resp="$(bi_response_by_id 1 "$out_file" || true)"
  if [ -n "$init_resp" ] && \
     printf '%s' "$init_resp" | jq -e '.jsonrpc == "2.0" and .id != null and .result != null' >/dev/null 2>&1; then
    bi_ok "offline boot: initialize returns a valid JSON-RPC result"
  else
    bi_bad "offline boot: no valid JSON-RPC initialize result (jsonrpc/id/result)"
  fi

  # 4. tools/list lists at minimum every required tool name. Compute the missing
  #    set with a whole-line fixed-string anti-join (required lines NOT present
  #    among the returned names) — shell-agnostic, no word-splitting.
  local tools_resp names missing
  tools_resp="$(bi_response_by_id 2 "$out_file" || true)"
  names="$(printf '%s' "$tools_resp" | jq -r '.result.tools[].name' 2>/dev/null)"
  missing="$(printf '%s\n' "$BI_REQUIRED_TOOLS" \
    | grep -vxF -f <(printf '%s\n' "$names") 2>/dev/null | tr '\n' ' ')"
  if [ -z "$missing" ]; then
    bi_ok "offline boot: tools/list includes all required tools"
  else
    bi_bad "offline boot: tools/list missing: $missing"
  fi

  rm -rf "$sandbox"
  [ "$BI_FAIL" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Combined entry point — what the release workflow (M5-5) calls.
# ---------------------------------------------------------------------------
# bi_assert_integrity <repo_root>
#   Checksum drift guard + offline-boot proof. Returns non-zero iff any
#   assertion failed, so a CI/release step can gate on `bash -c 'source … &&
#   bi_assert_integrity "$PWD"'`'s exit status without re-implementing anything.
bi_assert_integrity() {
  local repo_root="$1"
  bi_assert_checksum "$repo_root"
  bi_assert_boot "$repo_root"
  [ "$BI_FAIL" -eq 0 ]
}
