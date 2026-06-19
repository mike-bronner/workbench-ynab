# Spike — Bundled-own YNAB MCP vs. the vendored third-party dependency

> **Type:** Spike (decision + sizing — **no production MCP code**).
> **Issue:** [#86](https://github.com/mike-bronner/workbench-ynab/issues/86) · Sprint 6 / v-Next [M6-8].
> **Status:** Recommendation issued.
> **Related:** [#87](https://github.com/mike-bronner/workbench-ynab/issues/87) (swap-ready abstraction — the linchpin), [#78](https://github.com/mike-bronner/workbench-ynab/issues/78) (offline-boot gate this follow-on must mirror).

## TL;DR — Recommendation: **BUILD-LATER (conditional)**

Ship v1 on the vendored third-party MCP (`@dizzlkheinz/ynab-mcpb@0.26.10`). **Do
not** build a bundled-own replacement now. Instead:

1. **Land [#87](https://github.com/mike-bronner/workbench-ynab/issues/87) first** — the swap-ready abstraction. It collapses the swap
   cost from a fragile, parity-dependent *O(N)* edit across every skill to a
   robust *O(1)* edit of a single adapter module. Without it, "swap-ready" is a
   slogan, not a property.
2. **Keep the vendored bundle for v1.** It carried the read-only prototype for
   months and gives zero-config, offline, frozen boot — exactly v1's promise.
3. **Trigger the bundled-own build only on a concrete need** (see
   [§5 Triggers](#triggers-that-flip-later--build-now)). Building a permanent
   maintenance commitment before the risk materializes is premature.

The risk that motivates this spike (an unmaintained, opaque, third-party
dependency we don't control) is **latent, not active**. The correct hedge is
**insulation, not replacement**: make the swap cheap, then defer it until it pays
for itself.

---

## 1. Friction inventory — the vendored `@dizzlkheinz/ynab-mcpb@0.26.10`

Concrete limitations of depending on the third-party bundle. Items marked
*observed* were seen running the prototype; *latent* are structural risks of the
dependency that have not yet bitten.

| # | Friction | Kind | Impact |
|---|----------|------|--------|
| 1 | **Tool surface is not ours.** Tool names, parameters, and shapes are the upstream author's design (`list-budgets`, `list-transactions`, …). We inherit their hyphenated naming and any quirks. | latent | Couples our skills to an external naming contract (see [§4](#4-swap-cost)). |
| 2 | **Maintenance risk.** Single-maintainer npm package, version-frozen at `0.26.10`. We neither auto-inherit fixes nor control the release cadence. If it stops tracking the YNAB API, we are stuck. | latent | The core reason this spike exists. |
| 3 | **Opaque, un-auditable artifact.** Shipped as a prebuilt ~1.46 MB `dist/bundle/index.cjs`. We cannot easily audit, patch, or trim it; provenance is a separate Sprint 1 gap item. | latent | Supply-chain + security surface. |
| 4 | **Delta / `server_knowledge` support unverified.** YNAB supports `last_knowledge_of_server` for cheap incremental pulls. If the MCP does not expose this param, every poll is a full fetch — fatal for the M6-1 between-run **monitor**, which needs cheap, frequent polls under the rate limit. | latent (blocks M6-1) | Forces full pulls; burns the rate budget. |
| 5 | **Rate-limit handling unknown.** YNAB allows **200 requests/hour per token** (rolling). Whether the MCP surfaces `429`, backs off, or just errors is opaque. Fine for a weekly review; risky for monitoring (M6-1) and batch write-back (Sprint 4). | latent | Unpredictable failure under load. |
| 6 | **Error semantics opaque.** How the MCP maps YNAB errors (`401` revoked token, `404` budget, `429` rate limit, partial-batch failures) onto MCP tool errors is undocumented. Sprint 4's write-safety guardrail needs **predictable, typed** errors. | latent (affects Sprint 4) | Hard to build safe write-back on top. |
| 7 | **Milliunit ergonomics.** YNAB amounts are integer **milliunits**; the prototype divides by 1000 by hand (`SKILL.md` line 168). The MCP passes raw milliunits through, so every skill must convert — which is exactly why the roadmap mandates one shared money helper (correction #8). | observed | Per-skill conversion burden (mitigated by the helper, not the MCP). |
| 8 | **Long namespace prefix.** Under the `mcpServers.ynab` key the tools surface as `mcp__plugin_workbench-ynab_ynab__<tool>` (e.g. `…__list-budgets`). Verbose, and embeds the upstream's hyphen style. | observed | Cosmetic; but the prefix is also the swap advantage (see [§4](#4-swap-cost)). |
| 9 | **Write-tool semantics unexercised.** The prototype was **read-only** (`SKILL.md` line 167). Sprint 4 needs categorize / allocate / dedup / reconcile / create / update / delete with dry-run + idempotency. Whether the third-party write tools provide those semantics is unverified. | latent (blocks Sprint 4 confidence) | Biggest unknown for v1's write phase. |

**Takeaway:** almost every friction is *latent* — a risk of not controlling the
dependency, not a bug we hit today. The one *observed* friction (milliunits) is
already handled by a shared helper, independent of which MCP sits underneath.
That profile argues for *insulation now, replacement on trigger* — not a
speculative rebuild.

---

## 2. YNAB API coverage map

YNAB ships a documented public REST API — base `https://api.ynab.com/v1`, auth
`Authorization: Bearer <token>`, JSON. The ~30 namespaced tools map cleanly onto
it. (Exact vendored tool **names** must be confirmed against `dist/bundle/index.cjs`
during the build; the read names below are confirmed from the prototype's
`SKILL.md` Setup section.)

### 2.1 Read tools → endpoints

| Tool (namespaced `…_ynab__`) | YNAB REST endpoint | Used by | Confirmed |
|---|---|---|---|
| `list-budgets` | `GET /budgets` | review setup | ✅ prototype |
| `get-budget` | `GET /budgets/{b}` (supports `last_knowledge_of_server`) | delta/monitor | inferred |
| `get-budget-settings` | `GET /budgets/{b}/settings` | currency/format | inferred |
| `list-accounts` / `get-account` | `GET /budgets/{b}/accounts[/{a}]` | balances, reconcile | ✅ prototype |
| `list-categories` / `get-category` | `GET /budgets/{b}/categories[/{c}]` | classification | ✅ prototype |
| `get-month-info` / `list-months` | `GET /budgets/{b}/months[/{m}]` | budget health | ✅ prototype |
| `get-month-category` | `GET /budgets/{b}/months/{m}/categories/{c}` | allocate read | inferred |
| `list-transactions` (+ by account/category/payee) | `GET /budgets/{b}/transactions` etc. | the core pull | ✅ prototype |
| `get-transaction` | `GET /budgets/{b}/transactions/{t}` | detail | inferred |
| `list-payees` / `get-payee` | `GET /budgets/{b}/payees[/{p}]` | dedup, classification | ✅ prototype |
| `list-payee-locations` | `GET /budgets/{b}/payee_locations` | (unused today) | inferred |
| `list-scheduled-transactions` / `get-…` | `GET /budgets/{b}/scheduled_transactions[/{s}]` | forecast, bills | ✅ prototype |
| `get-user` | `GET /user` | auth check | inferred |

### 2.2 Write tools → endpoints (needed for Sprint 4)

| Tool | YNAB REST endpoint | Review use |
|---|---|---|
| `create-transaction` / `create-transactions` | `POST /budgets/{b}/transactions` (single or array) | rare (manual add) |
| `import-transactions` | `POST /budgets/{b}/transactions/import` | bank import |
| `update-transaction` | `PUT /budgets/{b}/transactions/{t}` | **categorize** |
| `update-transactions` (bulk) | `PATCH /budgets/{b}/transactions` | **bulk categorize** |
| `delete-transaction` | `DELETE /budgets/{b}/transactions/{t}` | **dedup** |
| `update-month-category` | `PATCH /budgets/{b}/months/{m}/categories/{c}` | **allocate** (`budgeted`) |
| `create/update/delete-scheduled-transaction` | `…/scheduled_transactions[/{s}]` | bill mgmt |

### 2.3 Minimum reimplement-worthy subset + per-group effort

The follow-on does **not** need all ~30. The minimum for v1 (review +
ledger-only write-back):

| Group | Tools | Endpoints | Effort (TS over official `ynab` SDK) |
|---|---|---|---|
| **Budget/structure reads** | list-budgets, get-budget (delta), get-budget-settings | 3 GETs | **S** — SDK one-liners; delta-cache wrapper is the only real code |
| **Account/category reads** | list-accounts, list-categories, get-month-info, list-months, get-month-category | 5 GETs | **S** |
| **Transaction reads** | list-transactions (+by-account/category/payee), get-transaction | 1 endpoint, 4 filters | **S** — pagination + `since_date` |
| **Payee reads** | list-payees, get-payee | 2 GETs | **XS** |
| **Scheduled reads** | list-scheduled-transactions, get-scheduled-transaction | 2 GETs | **XS** |
| **Transaction writes (categorize/dedup)** | update-transaction, update-transactions (bulk), delete-transaction, create-transactions | 4 endpoints | **M** — arg validation, bulk semantics, idempotency keys |
| **Allocation write** | update-month-category | 1 PATCH | **S** |
| **Reconcile** | *composite* — PATCH cleared→`reconciled` + optional adjustment txn | reuses txn endpoints | **M** — no native endpoint (see note) |

**Two API realities to flag (they constrain *any* MCP, vendored or bundled-own):**

- **No native "reconcile" endpoint.** Reconciliation = mark cleared transactions
  `cleared: "reconciled"` (a `PATCH`/`PUT` on transactions) plus, optionally, a
  balance-adjustment transaction. It is a *composite*, not a primitive — the
  bundled-own MCP would implement it as orchestration over existing endpoints.
- **"Ready to Assign" is not directly settable.** The API can set a category's
  `budgeted` amount for a month; RTA is *derived*. "Allocate Ready-to-Assign"
  therefore means moving `budgeted` between categories, not writing an RTA field.

Total minimum subset ≈ **18–20 tools**. Reads are nearly free over the official
SDK; the real engineering is in the write group (validation, bulk, idempotency,
reconcile composite) and the delta cache.

---

## 3. Build option spec

Concrete spec for the follow-on **if/when triggered**. At least one option is
specified in full; a language fork is presented because it has long-term
consequences.

### 3.1 Language fork

1. **Node / TypeScript** — esbuild → single self-contained `dist/bundle/index.cjs`.
   - *Pros:* matches the **existing** prerequisite (the plugin already requires
     system `node`; README "Prerequisites"). Official **`ynab` JS SDK** removes
     the HTTP/JSON burden. Ships as a **drop-in replacement** for the current
     vendored `.cjs` under the same launcher and `mcpServers.ynab` key — identical
     offline-boot story. Tool-name/shape parity with the upstream (also Node) is
     trivial.
   - *Cons:* TypeScript build toolchain (esbuild) to maintain; SDK is one more
     dependency to track.

2. **Python / uv** — mirrors the memory MCP's toolchain (`mcp-memory.sh` bootstraps
   a Python server via `uv tool install`).
   - *Pros:* consistent with `workbench-core`'s memory server pattern.
   - *Cons:* adds a **Python runtime prerequisite the YNAB plugin otherwise does
     not need** (README requires `node`, not Python). YNAB's official SDK is
     JS-first. Breaks the "single vendored `.cjs` + system node" boot model — more
     divergence, not less.

**Recommendation: Node/TypeScript.** It preserves the zero-extra-prerequisite
property and lets the bundled-own MCP ship as a byte-for-byte structural
replacement of today's vendored artifact — same launcher, same `exec node …`,
same offline-boot gate.

### 3.2 Launcher shape (mirrors `~/Developer/workbench-core/hooks/mcp-memory.sh`)

Same discipline as the memory launcher — **jq config read, stderr-only logging,
`exec` the server** — minus the self-install bootstrap (the bundle is vendored,
so there is nothing to install at runtime; this is *simpler* than the memory
launcher and matches today's vendored boot exactly):

```bash
#!/usr/bin/env bash
set -u

# stdout is the MCP stdio (JSON-RPC) channel. Every byte of diagnostics MUST go
# to stderr — one stray stdout line corrupts the handshake. (Same rule as
# mcp-memory.sh.)
_log() { echo "ynab-mcp: $*" 1>&2; }

# --- Auth: token from macOS Keychain, never from disk, never logged ----------
TOKEN=$(security find-generic-password -s workbench-ynab -a YNAB_ACCESS_TOKEN -w 2>/dev/null)
if [ -z "$TOKEN" ]; then
  _log "ERROR: YNAB token not in Keychain. Run /workbench-ynab:setup."
  exit 1
fi
export YNAB_ACCESS_TOKEN="$TOKEN"

# --- Optional config via jq (single source of truth; plugin.json just points here)
CONFIG_FILE="$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json"
_cfg() {
  [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 \
    && jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null
}
export YNAB_DEFAULT_BUDGET="$(_cfg '.default_budget_id')"
export YNAB_LOG_LEVEL="$(_cfg '.log_level')"

# --- Frozen, self-contained, offline: no npx, no runtime install -------------
exec node "${CLAUDE_PLUGIN_ROOT}/vendor/ynab-mcp/dist/bundle/index.cjs"
```

Deltas from `mcp-memory.sh`: **no bootstrap/self-install block** (vendored, not
installed-on-demand — a parity win with today's bundle); **Keychain auth**
instead of a path env; otherwise identical stderr-only + `jq` + `exec` shape.
Reuses the existing `bin/launcher.sh` contract so `plugin.json`'s
`mcpServers.ynab` entry is **unchanged**.

### 3.3 Auth & rate-limit surface

- **Auth:** YNAB Personal Access Token, `security(1)` Keychain →
  `YNAB_ACCESS_TOKEN` env → `Authorization: Bearer`. Never on disk, never logged
  (matches README privacy posture). Rotation = re-run setup.
- **Rate limit:** 200 req/hr per token, rolling. Strategy:
  - **Delta requests** (`last_knowledge_of_server`) — fetch full once, then only
    changes; cache `server_knowledge` per `(budget, endpoint)` in `run/` state.
    This is the unlock the vendored MCP's support is *unverified* for (friction #4).
  - **Single-flight** — stdio MCP is single-client; serialize requests.
  - **On `429`** — honour rate-limit headers, exponential backoff + jitter, surface
    a typed `RateLimitError` so skills degrade gracefully (weekly review can wait;
    M6-1 monitor can skip a poll).
  - **Batch writes** via bulk endpoints (`PATCH /transactions`) to spend fewer
    requests per apply (Sprint 4).

---

## 4. Swap cost

**The migration advantage:** the namespace prefix
`mcp__plugin_workbench-ynab_ynab__<tool>` is derived from
`{plugin}_{serverKey}_{toolName}`. A bundled-own MCP behind the **same**
`mcpServers.ynab` key in `plugin.json`, launched by the **same** `bin/launcher.sh`,
and exposing the **same tool names**, produces **byte-identical** namespaced tool
identifiers. So a clean swap can preserve every call site's tool name — the
plugin/server/launcher contract never changes; only the `exec`'d bundle does.

Two cases for ritual-file churn:

| Case | What skills bind to | Swap cost | Risk |
|---|---|---|---|
| **Without [#87](https://github.com/mike-bronner/workbench-ynab/issues/87)** | Raw tool names `mcp__plugin_workbench-ynab_ynab__list-transactions`, … scattered across ~12 skills (Sprint 3 review tiers + Sprint 4 write paths) | **Near-zero *only if* exact name + signature parity holds.** Any drift (a renamed tool, a changed param) ⇒ edit **every** call site. Delta: **0 files (perfect parity)… N skill files (any drift)**. | Parity is a hard, easily-violated constraint. One "improved" signature breaks the swap. *O(N)*, fragile. |
| **With [#87](https://github.com/mike-bronner/workbench-ynab/issues/87)** | A facade — e.g. `ynab.listTransactions(...)` — in one adapter module; skills never name raw tools | **Edit one adapter** mapping facade → MCP tool calls. Delta: **1 file, always**, regardless of name/signature drift. The facade can even *normalize* (typed errors, currency) behind a stable interface. | *O(1)*, robust. |

**Conclusion — the spike's central finding:** [#87](https://github.com/mike-bronner/workbench-ynab/issues/87) is the precondition that makes a
bundled-own MCP cheap to adopt. It converts the swap from *fragile,
parity-dependent O(N)* to *robust O(1)*. **#87 must land before any bundled-own
build is greenlit** — building the MCP without it just moves the coupling around.

---

## 5. Recommendation — **BUILD-LATER (conditional)**

**Decision:** do **not** build now; keep the vendored third-party MCP for v1; land
[#87](https://github.com/mike-bronner/workbench-ynab/issues/87) so the swap is cheap; build the bundled-own MCP only on a concrete trigger.

**Rationale:**

- **The vendored MCP is sufficient for v1.** It carried the read-only prototype
  for months, covers the tools the review needs, and delivers the zero-config,
  offline, frozen boot that is v1's whole pitch.
- **The risk is latent, not active** ([§1](#1-friction-inventory--the-vendored-dizzlkheinzynab-mcpb02610)). Eight of nine frictions are
  "we don't control it" risks that have not bitten. Rebuilding to pre-empt a risk
  that may never fire is premature, and a bundled-own MCP is a **permanent**
  maintenance commitment (we'd track the YNAB API ourselves, forever).
- **Insulation beats replacement.** [#87](https://github.com/mike-bronner/workbench-ynab/issues/87) gives 90% of the safety (cheap, fast
  swap on demand) for ~10% of the cost (one adapter module vs. a whole MCP +
  ongoing upkeep).

### Triggers that flip "later" → "build now"

Build the bundled-own MCP when **any** of these becomes real:

1. **A ritual needs a tool the vendored MCP lacks or gets wrong** — e.g.
   delta/`server_knowledge` for the M6-1 monitor (friction #4), or correct
   bulk-write / reconcile semantics for Sprint 4 (friction #9).
2. **The upstream goes stale** against a breaking YNAB API change and isn't fixed
   in reasonable time (friction #2).
3. **Write-back safety (Sprint 4)** needs error / dry-run / idempotency semantics
   the third-party tools can't provide predictably (friction #6).
4. **A security/provenance concern** with the opaque 1.46 MB bundle (friction #3).

### Rough sizing for the follow-on (if triggered)

| Scope | LOC (TypeScript, over official `ynab` SDK + `@modelcontextprotocol/sdk`) | Effort |
|---|---|---|
| **MVP parity** — reads + ledger-only writes (~18–20 tools) | **~800–1,200** (tool defs + arg validation + error mapping + delta cache; SDK handles HTTP/JSON) + ~150 launcher/esbuild | **~3–5 working days** incl. tests + offline-boot gate |
| **Full ~30-tool parity** | **~1,500–2,000** | +~2 days |
| **Ongoing maintenance** | — | low-but-nonzero: watch YNAB API changelog, re-bundle on SDK bumps |

### Minimum tool-parity checklist

The bundled-own MCP must expose these with **identical names + compatible
signatures** (so the swap preserves call sites / the [#87](https://github.com/mike-bronner/workbench-ynab/issues/87) adapter stays thin):

**Reads** — `list-budgets`, `get-budget` (with `last_knowledge_of_server`),
`list-accounts`, `list-categories`, `get-month-info` / `list-months`,
`get-month-category`, `list-transactions` (+ by account / category / payee),
`get-transaction`, `list-payees`, `list-scheduled-transactions`.

**Writes (Sprint 4)** — `create-transactions`, `update-transaction`,
`update-transactions` (bulk), `delete-transaction`, `import-transactions`,
`update-month-category` (allocate), `reconcile` (composite: PATCH
cleared→`reconciled` + optional adjustment txn).

---

## 6. Offline-boot gate (the follow-on's test plan)

Because the recommendation includes a build path, the follow-on must pass the
**same offline-boot gate the vendored bundle passes** — mirroring
[#78](https://github.com/mike-bronner/workbench-ynab/issues/78) ("end-to-end verification checklist and offline-bundle-boot test"),
extended with a tool-list parity snapshot specific to the swap:

1. **Bundle presence + provenance.** `vendor/ynab-mcp/dist/bundle/index.cjs`
   exists, is tracked in git, and its SHA is recorded in a version marker; the
   bundle is reproducible from pinned SDK versions (ties into Sprint 1's bundle
   provenance check).
2. **Offline boot (network disabled).** `bash bin/launcher.sh` starts the MCP and
   completes the JSON-RPC `initialize` handshake using **only** the vendored
   bundle + system `node` — no `npm install`, no `npx`, no network. (Tool *calls*
   need network/YNAB; *boot* must not.)
3. **stdout cleanliness.** Assert **zero** non-JSON-RPC bytes on stdout during
   boot — all diagnostics on stderr. This is the exact corruption class
   `mcp-memory.sh` guards against.
4. **Token-absent failure mode.** With no Keychain token, the launcher exits
   non-zero with a clear **stderr** message and emits nothing on stdout (no stack
   trace on the JSON-RPC channel).
5. **Tool-list parity snapshot.** `tools/list` returns exactly the
   parity-checklist tool names (golden snapshot in CI) — a swap that drops or
   renames a tool **fails CI**. This is the swap-specific addition to #78's
   checklist.
6. **Min-Node pin.** Boot under the pinned minimum Node version (Sprint 1's
   min-Node-pin gap item) to catch runtime-version regressions.

Passing this gate is the bar for greenlighting the swap — identical in spirit to
the gate the vendored bundle already clears.

---

## References

- **Vendoring facts** — `docs/ROADMAP.md` (Decisions table): `@dizzlkheinz/ynab-mcpb@0.26.10`,
  self-contained ~1.46 MB `dist/bundle/index.cjs`, run via `node`, frozen in git,
  no `npx`-on-demand; token via Keychain → `YNAB_ACCESS_TOKEN`.
- **Launcher reference** — `~/Developer/workbench-core/hooks/mcp-memory.sh`
  (jq config read, stderr-only logging, `exec` server, bootstrap-on-missing — which
  the vendored YNAB launcher omits because the bundle is in-repo).
- **Prototype tool usage** — `~/Documents/Claude/Scheduled/ynab-financial-review/SKILL.md`
  (Setup: `list-budgets`, `list-accounts`, `list-categories`, `list-transactions`,
  `list-payees`, `get-month-info`, `list-scheduled-transactions`; read-only;
  milliunits ÷ 1000).
- **Plugin wiring** — `.claude-plugin/plugin.json` (`mcpServers.ynab` →
  `bin/launcher.sh`), confirming the namespace-preservation swap advantage.
- **Cross-refs** — [#87](https://github.com/mike-bronner/workbench-ynab/issues/87) (swap-ready abstraction — land first),
  [#78](https://github.com/mike-bronner/workbench-ynab/issues/78) (offline-bundle-boot gate to mirror).

> **Not tax advice.** This document concerns plugin architecture only.
