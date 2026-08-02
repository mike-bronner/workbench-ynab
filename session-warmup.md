## 💰 workbench-ynab routing

The `workbench-ynab` plugin is active — tax-aware YNAB budget review. **Milestone 2 is READ-ONLY:** review, categorization *proposals*, and reports only — never call a write/mutation tool, never move money. Propose changes for the user to apply later.

**Tools are namespaced `mcp__plugin_workbench-ynab_ynab__*`** — NOT `mcp__ynab__*`. Never hard-code a tool name; resolve it from the `ynab-protocol` skill (`skills/protocol/ynab-tools.md`), the single source of truth.

**Config / token split:** the YNAB access token is read from the macOS Keychain by the launcher (`bin/launcher.sh`) and handed to the MCP as `YNAB_ACCESS_TOKEN` — the ONLY thing the MCP ever sees. All budget / tax / profile / persona configuration lives in `config.json` under the plugin data-dir and is read by the SKILLS (`bin/config.sh`); it is never passed to the MCP.

### Trigger vocabulary → route

| The user asks about… | Route to |
|---|---|
| their budget / a category / month-to-date spend | the YNAB review skills — read-only |
| a transaction / payee / a possible duplicate | the YNAB review skills — read-only |
| categorization / "how should X be categorized?" | the categorize proposal path — proposes only, never writes |
| taxes / estimated tax / a tax-category rollup | the estimated-tax review skill — read-only |
| "run my review" / a weekly, monthly, quarterly-tax, or annual review | `/workbench-ynab:ynab-review` — the one entry point |
