# Fresh-machine (clean-room) install test

> ⚠️ Estimates only — not tax advice. Consult a qualified professional before filing or paying.

> **Type:** Clean-room install proof (M5-10). The vendoring decision promises a
> fresh machine needs **no `npx`-on-demand and no `node_modules` install** — the
> vendored bundle boots on a bare system `node`. This document is the procedure
> to **prove that on a clean environment**, plus the **recorded results** of a
> run. It validates the README install instructions (M5-1) end to end.

This is one of three complementary release proofs — do not conflate them:

| Proof | What it guarantees | Who runs it |
|---|---|---|
| [`../tests/offline-boot.sh`](../tests/offline-boot.sh) (M5-9) | the committed bundle *boots* offline, node_modules-free, exposing the tool set — in CI on every PR | automated |
| **This document** (M5-10) | the whole **install → setup → run** path works on a **clean profile** | maintainer, on a fresh account / sandboxed `$HOME` |
| [`verification-checklist.md`](verification-checklist.md) (M5) | the plugin *behaves* end to end with a **real token** on a real machine | maintainer, once before cutting `1.0.0` |

## Fidelity — what "clean room" means here

Full fidelity is a **fresh macOS user account** with a **real YNAB Personal
Access Token**. Where a spare account is impractical, run in a **sandboxed
`$HOME`** (a throwaway `HOME` pointing the config and Keychain lookups at empty
state). Either way, start from **no prior plugin config and no Keychain entry**.

Some steps require a **live Claude Code session driving the plugin's namespaced
MCP** and a **real token** — the interactive `setup`, the live `ynab_list_budgets`
call against the YNAB API, the read-only review, and the rendered HTML report.
Those are **human-run only**: they cannot be exercised headlessly, so they are
executed as part of the human release gate in
[`verification-checklist.md`](verification-checklist.md). The mechanical,
token-free half — prerequisites, the offline bundle boot, the MCP handshake and
tool registration, first-connection latency, the config-path and pre-approval
assertions — **is** scriptable and is what the [Results](#results) section below
records from an actual run.

---

## Procedure

### Step 0 — Prepare the clean room

Create the clean environment and confirm it carries no prior state:

```bash
# Option A — a fresh macOS user account (highest fidelity): log in as a new
# user, then work from its home directory.
#
# Option B — a sandboxed HOME in the current account:
SANDBOX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ynab-clean-room.XXXXXX")"
export HOME="$SANDBOX_HOME"          # config + settings.json now resolve here

# Assert the clean-room preconditions: no plugin config, no prior review output.
test ! -e "$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json" \
  && echo "✅ no prior config" || echo "❌ prior config present — not a clean room"
```

> The macOS Keychain is **account-scoped, not `$HOME`-scoped**: a sandboxed
> `$HOME` still shares the login account's Keychain. Use a Keychain entry name
> you can delete afterward, or run Option A. Confirm no prior entry:
> `security find-generic-password -s ynab-mcp -a access-token >/dev/null 2>&1 && echo "entry exists — remove before testing" || echo "✅ no prior Keychain entry"`.

### Step 1 — Assert the prerequisites (all four; fail fast)

The plugin's four prerequisites are `node` (at or above the pinned floor in
[`../vendor/ynab-mcp/NODE_VERSION`](../vendor/ynab-mcp/NODE_VERSION)), `jq`,
`security(1)`, and `workbench-core`. This check mirrors the dev-team setup
Step 2 pattern — collect every miss, print actionable guidance, and **fail fast
with a non-zero exit** if any is absent — and extends it to `workbench-core`,
which the plugin's own `setup` Step 1a does not yet assert (see
[Gaps found](#gaps-found)):

```bash
missing=()
for cmd in node jq security; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
# workbench-core is a Claude Code plugin, not a CLI: assert its install footprint
# under the plugins cache (marketplace or local checkout both land here).
ls -d "$HOME"/.claude/plugins/cache/*/workbench-core >/dev/null 2>&1 \
  || missing+=("workbench-core")

if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing prerequisites: ${missing[*]}"
  for m in "${missing[@]}"; do
    case "$m" in
      node)          echo "   • node — install the newest Node LTS (nvm, brew install node, …)" ;;
      jq)            echo "   • jq — brew install jq" ;;
      security)      echo "   • security — ships with macOS; this plugin is macOS-only" ;;
      workbench-core) echo "   • workbench-core — claude plugin install workbench-core@claude-workbench" ;;
    esac
  done
  echo "   Install the missing prerequisite(s) and re-run this procedure."
  exit 1
fi
echo "✅ node, jq, security, workbench-core all present"

# node on PATH is not enough — it must meet the vendored bundle's pinned floor.
NODE_FLOOR="$(cat vendor/ynab-mcp/NODE_VERSION)"   # from a checkout of this repo
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt "$NODE_FLOOR" ]; then
  echo "❌ workbench-ynab requires Node >= ${NODE_FLOOR}; you have $(node --version) — upgrade your Node LTS."
  exit 1
fi
echo "✅ node $(node --version) meets the Node >= ${NODE_FLOOR} floor"
```

A miss here is a **hard stop** — do not proceed to install with a prerequisite
absent or a below-floor Node.

### Step 2 — Install the plugin (both paths)

The README documents two install paths; a clean-room run should confirm **both**.

**From the marketplace:**

```
claude plugin marketplace add mike-bronner/claude-workbench
claude plugin install workbench-ynab@claude-workbench
```

**From a local checkout (development):**

```
git clone https://github.com/mike-bronner/workbench-ynab
cd workbench-ynab
claude plugin install /absolute/path/to/workbench-ynab
```

Either path vendors the frozen bundle in place — **no `node_modules` install and
no `npx`-on-demand run at any point**. Confirm the vendored bundle arrived intact:

```bash
bash vendor/ynab-mcp/verify-bundle.sh   # committed bundle matches its marker hash
```

### Step 3 — Restart Claude Code

Restart so the plugin's agents, skills, commands, and the vendored MCP server are
picked up. The namespaced MCP key is `ynab` (server `mcpServers.ynab` in
[`../.claude-plugin/plugin.json`](../.claude-plugin/plugin.json)), giving the tool
prefix `mcp__plugin_workbench-ynab_ynab__`.

### Step 4 — Run setup

```
/workbench-ynab:setup
```

Setup seeds the YNAB token into the Keychain, writes `config.json` outside the
repo, and pre-approves the read-only tool glob. It is idempotent — see
[`../commands/setup.md`](../commands/setup.md).

### Step 5 — Assert the config landed out of repo

The config must live **outside** the installed plugin tree so plugin updates
never clobber it:

```bash
CONFIG="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json"
test -f "$CONFIG" && echo "✅ config at $CONFIG" || echo "❌ config not at the documented path"
```

### Step 6 — Assert the token is ONLY in the Keychain

The token belongs in the Keychain (service `ynab-mcp`, account `access-token`)
and **nowhere else** — not in `config.json`, not in any file in the repo or the
plugin directory. Prove both halves:

```bash
# a) config.json carries no token-shaped (64-hex) value — mirrors setup's own guard.
jq -e '[getpath(paths) | strings | test("^[0-9a-f]{64}$")] | any' "$CONFIG" \
  >/dev/null 2>&1 && echo "❌ token-shaped value in config.json" || echo "✅ config.json is token-free"

# b) the token value appears in no file, across BOTH trees the promise covers:
# the repo checkout AND the installed plugin cache under ~/.claude/plugins. Feed
# the secret over STDIN (-f -) so it never lands in argv / ps / shell history,
# abort on an empty lookup (an empty pattern matches every line → false alarm),
# and drive the verdict off whether grep produced filenames — never its exit status.
SWEEP_ROOTS=( . )                                                            # the repo checkout
[ -d "$HOME/.claude/plugins" ] && SWEEP_ROOTS+=( "$HOME/.claude/plugins" )   # + the installed plugin tree
TOKEN="$(security find-generic-password -s ynab-mcp -a access-token -w)"
if [ -z "$TOKEN" ]; then
  echo "empty token — Keychain lookup failed; aborting sweep"
else
  hits="$(printf '%s\n' "$TOKEN" | grep -rIlF -f - "${SWEEP_ROOTS[@]}" 2>/dev/null)"
  if [ -n "$hits" ]; then echo "❌ LEAK FOUND in:"; printf '%s\n' "$hits"; else echo "✅ no leak — token is Keychain-only"; fi
fi
unset TOKEN
```

### Step 7 — Assert the pre-approval glob is namespaced

Setup pre-approves read tools by the **namespaced** prefix so the user is not
prompted on every call. The bare `mcp__<key>__` form never resolves — the entries
must carry the full `mcp__plugin_workbench-ynab_ynab__` prefix:

```bash
jq -r '.permissions.allow[]?' "$HOME/.claude/settings.json" \
  | grep -c '^mcp__plugin_workbench-ynab_ynab__' | xargs -I{} echo "namespaced read-tool approvals: {}"
# Expect ≥ 1, and every YNAB approval carrying the mcp__plugin_workbench-ynab_ynab__* prefix.
```

The concrete read-tool names come from the single source of truth,
[`../skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md).

### Step 8 — Verify the MCP connects and `ynab_list_budgets` returns

In the live session, the vendored MCP must answer a read-only call through the
namespaced tool with **no** manual token configuration beyond the Step 4 Keychain
seeding:

- Call the `ynab_list_budgets` read tool through the namespaced
  `mcp__plugin_workbench-ynab_ynab__*` glob (no arguments).
- **Pass when:** it returns your budget names.

**First-connection latency** — the vendored bundle + `node` spawn can lag on a
cold first launch. `bin/launcher.sh` itself documents **no** timeout of any kind;
the real cold-start budget lives in the orchestrator, which grants **20 s** of
boot patience (`~10 × 2 s`, per
[`../agents/ynab-orchestrator.md`](../agents/ynab-orchestrator.md) and
[`ynab-read-path.md`](ynab-read-path.md)). Measure the
spawn-to-first-response time over a few cold runs and call out any delay
approaching that **20 s boot-patience budget**. From a checkout, against a
`node_modules`-free sandbox mirroring a fresh machine:

```bash
FAKE_TOKEN='fake-boot-token-not-a-real-pat'   # any non-empty FAKE value — never a real YNAB PAT
for run in 1 2 3; do                          # a few cold runs, not a single shot
  SB="$(mktemp -d)"; mkdir -p "$SB/bin" "$SB/vendor/ynab-mcp"
  cp bin/ynab-mcp "$SB/bin/"; cp vendor/ynab-mcp/index.cjs "$SB/vendor/ynab-mcp/"
  ( cd "$SB"; export YNAB_ACCESS_TOKEN="$FAKE_TOKEN"
    S=$(node -e 'process.stdout.write(String(Date.now()))')
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"lat","version":"0"}}}' \
      | node bin/ynab-mcp 2>/dev/null | grep -m1 '"jsonrpc"' >/dev/null
    E=$(node -e 'process.stdout.write(String(Date.now()))')
    echo "run $run: spawn→first response ≈ $(( E - S )) ms" )
  rm -rf "$SB"
done
```

### Step 9 — Run a read-only review; confirm the report renders

This criterion has two halves — one is sandbox-provable now, one is human-run.

**Print-CSS half (sandbox-provable).** The rendered report is built from the
frozen template
[`../assets/report/template.html`](../assets/report/template.html), whose
`<style>` block ships the `@media print` rule. That the template carries the
print CSS is proven **offline** by
[`../tests/report-template.test.sh`](../tests/report-template.test.sh) (it
asserts the `@media print` block and the full print contract), so this half needs
no live token:

```bash
grep -c "@media print" assets/report/template.html   # expect ≥ 1 (frozen template)
bash tests/report-template.test.sh                    # expect "N passed, 0 failed", exit 0
```

**Live-review half (human-run).** Run the weekly review (read-only path — it
pulls budget, accounts, transactions and renders a report; it proposes nothing
yet). **Pass when** the review completes, makes **no** writes to YNAB, and writes
a polished HTML report whose rendered `<style>` block includes the same
`@media print` rule:

```bash
grep -c "@media print" path/to/report.html   # expect ≥ 1
```

### Step 10 — Offline-boot cross-check

Finally, run the automated bundle-boot proof from the checkout — the linchpin of
the vendoring decision, proving the bundle boots with no network and no
`node_modules`:

```bash
bash tests/offline-boot.sh   # expect: "N passed, 0 failed", exit 0
```

---

## Results

**Run recorded:** 2026-07-17 · branch
`chore/69-run-and-document-a-fresh-machine-clean-room-install` (at HEAD) · macOS
darwin · `node v24.18.0` · `jq-1.7.1` · `security(1)` present · `workbench-core`
installed at `~/.claude/plugins/cache/claude-workbench/workbench-core/`.

Steps split into **sandbox-executed** (run headlessly against a checkout and a
`node_modules`-free sandbox) and **human-run only** (require a live Claude Code
session + real token — deferred to
[`verification-checklist.md`](verification-checklist.md)).

### Sandbox-executed — actual outcomes

| Step | Check | Result |
|---|---|---|
| 1 | Prerequisites present (`node`, `jq`, `security`, `workbench-core`) | ✅ all four present |
| 1 | Node meets the pinned floor | ✅ `v24.18.0` ≥ floor `24` |
| 2 | Vendored bundle intact (`verify-bundle.sh`) | ✅ bundle SHA-256 matches `vendored.json`; no `node_modules`, no `npx` |
| 5 | Config path is the documented out-of-repo location | ✅ path asserted: `~/.claude/plugins/data/workbench-ynab-claude-workbench/config.json` (the exact path `setup` writes, per [`../commands/setup.md`](../commands/setup.md)) |
| 6a | `config.json` token-shaped-value guard | ✅ scan clean (guard logic verified against `setup` Step 4) |
| 7 | Pre-approval glob is namespaced | ✅ prefix `mcp__plugin_workbench-ynab_ynab__` confirmed against the SSoT [`../skills/protocol/ynab-tools.md`](../skills/protocol/ynab-tools.md) |
| 8 | MCP handshake + `ynab_list_budgets` registered | ✅ `initialize` + `tools/list` succeed offline; `ynab_list_budgets` present in the returned tool set (mechanical half — the live API call is human-run) |
| 8 | First-connection latency | ✅ spawn→first response ≈ **482–531 ms** across 3 cold runs — **far** below the 20 s boot-patience budget (~40× headroom); no first-run delay observed |
| 9 | Report template ships the print CSS (`@media print`) — offline proof | ✅ frozen `assets/report/template.html` has 6 `@media print`; `tests/report-template.test.sh` **55 passed, 0 failed** (print-CSS half — the live-review render is human-run) |
| 10 | Offline-boot proof (`tests/offline-boot.sh`) | ✅ **5 passed, 0 failed**, exit 0, ~1.1 s wall |

### Human-run only — deferred to the release gate

These require a live Claude Code session driving the namespaced MCP and a **real**
YNAB token; they cannot run headlessly and are exercised in
[`verification-checklist.md`](verification-checklist.md):

| Step | Check | Where it runs |
|---|---|---|
| 2 | `claude plugin install` (both paths) + restart | verification-checklist §1 |
| 4 | Interactive `setup` — real token seeded to Keychain | verification-checklist §1–2 |
| 6b | Full-tree token-leak sweep (needs the real token present) | verification-checklist §2 & §8 |
| 8 | Live `ynab_list_budgets` returns real budget names | verification-checklist §3 |
| 9 | Read-only review completes + the **live** report renders (behavioral half; the frozen template's `@media print` is sandbox-proven above) | verification-checklist §3–4 |

The sandbox run proves the **mechanical** install/boot path (the part the
vendoring decision is about) end to end; the behavioral half is proven by the
human release gate before `1.0.0`.

## Gaps found

- **`setup` does not assert the `workbench-core` prerequisite.** The README lists
  `workbench-core` as a prerequisite and this test's Step 1 asserts all four, but
  `setup` Step 1a ([`../commands/setup.md`](../commands/setup.md)) checks only
  `node`, `jq`, and `security`. A clean profile missing `workbench-core` would
  clear setup and only degrade later (persona name falls back, memory/session
  features unavailable). Low severity; filed as a follow-up:
  [#230](https://github.com/mike-bronner/workbench-ynab/issues/230).
- No other gaps surfaced in the sandbox-executed steps: the bundle boots offline,
  the config path is correct, the token stays Keychain-only, the pre-approval
  glob is namespaced, and first-connection latency is negligible.

> ⚠️ This procedure verifies plugin behaviour only. The plugin organizes
> financial data and surfaces tax-relevant signals; it is **not** a substitute
> for professional tax advice.
