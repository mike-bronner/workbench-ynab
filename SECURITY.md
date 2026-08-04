# Security Policy

`workbench-ynab` handles a **YNAB Personal Access Token (PAT) with write access
to a live financial budget** and ships a **vendored, prebuilt MCP bundle**. Two
guarantees are enforced at the repo level: **no secret is ever committed**, and
**the vendored bundle is integrity-pinned** so a tampered or drifted copy is
detectable.

These controls exist because of a real incident: a YNAB token once leaked into a
plaintext config and session logs. That post-mortem and its cleanup are tracked
as **M5-4 / issue #73** (see [Leaked token remediation](#leaked-token-remediation)
and [`docs/token-rotation.md`](docs/token-rotation.md)). This policy is the
forward-looking half — it prevents the next leak; #73 cleaned up the last one.

## Threat model

- **A live financial credential.** The YNAB PAT grants **write** access to a real
  budget. A leaked token lets an attacker read the full financial ledger and
  mutate it. The token is the crown jewel; every control below protects it.
- **A vendored supply-chain surface.** The only code that talks to the YNAB API
  is the vendored MCP bundle (`vendor/ynab-mcp/index.cjs`, ~1.46 MB, prebuilt and
  frozen). A drifted or tampered bundle is a supply-chain risk, so the bundle is
  integrity-pinned (see [Bundle integrity](#bundle-integrity)).
- **Out of scope.** This plugin never moves real money (see
  [No-real-money invariant](#no-real-money-invariant)); it cannot initiate
  transfers or payments, so the worst-case ledger mutation is reversible YNAB
  bookkeeping, not a real-world financial transaction.

## Where the token lives — macOS Keychain only

Your YNAB Personal Access Token is stored **only in the macOS Keychain**, under
service `ynab-mcp`, account `access-token`:

```bash
security find-generic-password -s "ynab-mcp" -a "access-token" -w
```

It is **never** committed to this repo, **never** written to a config file,
**never** placed in a `.env`/dotenv file, and **never** logged. The launcher
reads it fresh from the Keychain on every start and injects it into the vendored
MCP as the `YNAB_ACCESS_TOKEN` environment variable — it is never persisted
anywhere else. See the README "Privacy / where the token lives" section for the
user-facing summary.

## No-real-money invariant

Write-back is **strictly ledger-only**. Every write the plugin performs is one of
exactly four bookkeeping operations:

- **Categorize** — assign a transaction to a category.
- **Allocate** — move money from Ready-to-Assign into a category.
- **Fix duplicates** — delete a double-entered transaction.
- **Reconcile** — bring an account's cleared/reconciled balance into line.

**The plugin NEVER moves real money** — no transfers, no payments, nothing leaves
or moves between real accounts. This is enforced structurally: every change-set
carries a `money_movement: false` invariant that cannot be set otherwise, and a
runtime guardrail hard-blocks any apply that maps to a money-moving operation.
Writes are gated by an explicit read → propose → approve loop; one approval
covers one batch. See [`assets/changeset-contract.md`](assets/changeset-contract.md).

## Secret-hygiene enforcement

Two layers keep credentials out of version control:

1. **`.gitignore`** rejects secret-adjacent shapes before they can be staged:
   `.env*` (every dotenv variant, not just `.env`), `*.token`, `config.local.json`,
   `*.pem`, `*.key`, `keychain-dump*`, `*_token`, and `*access_token*`.
2. **A CI secret scan** — [`bin/secret-scan.sh`](bin/secret-scan.sh), wired into
   CI by [`.github/workflows/secret-scan.yml`](.github/workflows/secret-scan.yml)
   on every `push` and `pull_request`. It scans the working tree and **fails the
   build** on any of:
   - a **YNAB PAT shape** — a standalone 64-character lowercase-hex string;
   - a **cleartext token assignment** — `YNAB_ACCESS_TOKEN=` followed by a literal
     value (a `"$VAR"` reference, as the launcher uses, is not a leak and is not
     flagged);
   - a **PEM / private-key header** — any `BEGIN … PRIVATE KEY` block.

   The `vendor/` exclusion is **scoped to the hex rule only**: the bundle marker
   `vendor/ynab-mcp/vendored.json` legitimately carries 64-char-hex SHA-256
   digests that are indistinguishable from a YNAB PAT, so the hex rule skips
   `vendor/` to avoid false positives. The **cleartext-token and PEM rules still
   scan `vendor/`** — those shapes never legitimately appear in the bundle, so
   the ~1.46 MB vendored artifact (the repo's highest-risk supply-chain surface)
   is scanned for the unambiguous secret shapes.

   That exclusion is also **scoped to the repo-root `vendor/`, and only it**. The
   hex rule is handed an explicit list of top-level entries with the `./vendor`
   *directory* removed, rather than a `grep --exclude-dir=vendor` glob —
   `--exclude-dir` matches a directory's *basename at every depth*, so it also
   skipped any nested directory that merely happened to be named `vendor`, and a
   hex secret under `src/vendor/` was invisible to the rule (issue #276). A
   nested `vendor/` is now scanned by all three rules; only the one bundle
   directory the carve-out exists for is skipped, and only by the hex rule.
   A top-level *file* named `vendor` is not the bundle directory and is scanned
   like any other file — as it was under `--exclude-dir`, which never pruned
   files at all.

   **Every file is scanned as text, in the C locale.** The scan deliberately does
   *not* skip "binary" files: a single NUL byte anywhere in a file is enough for
   `grep` to classify the whole file as binary and skip it, which would hide a
   credential in that file from all three rules above — and this scan is the
   repo's only content-scanning CI gate, so one stray byte would silently shrink
   it to nothing (issue #255). The scanning `grep`s are pinned to `LC_ALL=C` for
   the same reason: under a UTF-8 locale `grep` decodes input as UTF-8, and a
   byte that is not valid UTF-8 makes it silently fail to match — no error, no
   warning, the credential simply reports as absent. CI runs under `LANG=C.UTF-8`,
   so that pin is what keeps the gate honest there. Scanning as text means grep would otherwise print raw
   file bytes, so reported hits are **sanitized and reported as `grep -o`
   matches**: a hit shows the matched shape rather than the whole physical line,
   bytes outside printable ASCII become `?`, and the text after the `path:line:`
   locator is capped at 200 characters with a `...` marker. The cap keeps the
   **head *and* the tail** of that text: because `grep -o` makes the match the
   record's suffix, keeping the tail guarantees the matched shape reaches the
   report even when the locator split mis-anchors — which it does on any path
   containing `:<digits>:`, since the split takes the leftmost one. (No such path
   is tracked here, but git accepts them, so the report does not rely on their
   absence.) That keeps a finding actionable (`path:line:match`) on a minified
   bundle, where the whole file can be one 500,000-character line and reporting
   the *line* would show unrelated code while silently truncating away the secret
   that tripped the rule. Bundle *integrity* verification
   is a **complementary** control, not a substitute for this scan:
   `verify-bundle.sh` detects drift, not secret content (see
   [Bundle integrity](#bundle-integrity)). The scanner is itself covered by a
   negative test, [`tests/secret-scan.test.sh`](tests/secret-scan.test.sh), which
   proves a synthetic, token-shaped string makes the scan exit non-zero — without
   ever committing such a string.

   **The scan fails closed, and says so with its own exit code** (issue #265).
   Each rule runs as a pipeline, and every stage's exit status is checked
   individually rather than collapsed into one number. `grep`'s routine "matched
   nothing" (exit 1) is the only non-zero the guard tolerates; any other non-zero
   from any stage means a tool failed to *run*, so the tree was never fully
   scanned and "clean" is not a conclusion the guard is entitled to draw. It
   therefore reports three distinct outcomes:

   | Exit | Meaning |
   |------|---------|
   | `0`  | The tree was fully scanned and no credential shape was found. |
   | `1`  | At least one likely credential was found. |
   | `2`  | The scan did not complete — a stage failed to run. **Not a clean result.** |

   An abort prints a `⚠ secret-scan ABORTED` block to stderr that names the
   failing stage and replays that tool's own diagnostic, which the scanning
   `grep`'s stderr redirect used to discard.

Beyond the YNAB token, the repo holds exactly one CI secret:
`DEVELOPER_SETTINGS_TOKEN`, a fine-grained PAT scoped to **Contents: Read and
write on `mike-bronner/claude-workbench` only**, used by release automation to
pin the released commit SHA in the workbench marketplace. It lives in GitHub
Actions secrets (never in the tree) and is documented in
[`docs/ci.md`](docs/ci.md).

## Launcher logging policy

The MCP launcher (`bin/launcher.sh`, issue #12) speaks the Model Context Protocol
over stdio, so its output discipline is a **security contract**, not a style
preference:

- **stdout is the JSON-RPC channel** and must never receive non-JSON output — a
  single stray stdout line corrupts the MCP handshake.
- **All diagnostic logging goes to stderr**, routed through a single `_log`
  helper; never `echo` to stdout.
- **The YNAB PAT must never be interpolated into any log or echo statement** —
  not to stdout, and **not even to stderr**, because a token written to stderr
  still lands in session logs (exactly the M5-4 / #73 leak). The token is passed
  to the exec'd process **only** via the `YNAB_ACCESS_TOKEN` environment
  variable, never via a log line.

This is the binding contract that `bin/launcher.sh` must satisfy; the current
launcher meets it (Keychain → `YNAB_ACCESS_TOKEN` env → `exec node`, with no
token ever echoed). Any change to the launcher must preserve all three rules.

## Bundle integrity

The vendored YNAB MCP bundle is the **frozen copy of record** — the only code
that touches the YNAB API. Its integrity is pinned so any hand-edit or drift
fails loudly:

- **`vendor/ynab-mcp/vendored.json`** records the bundle's provenance, including
  the `bundle_sha256` field — the SHA-256 of `vendor/ynab-mcp/index.cjs`.
- **[`vendor/ynab-mcp/verify-bundle.sh`](vendor/ynab-mcp/verify-bundle.sh)** is
  the authoritative verifier. It asserts the committed bundle's SHA-256 still
  matches the recorded `bundle_sha256` and that the entrypoint shim is present and
  executable. It is offline by design (pure `jq` + `shasum`, no node, no network).

Verify the bundle from the repo root:

```bash
bash vendor/ynab-mcp/verify-bundle.sh
```

It prints each check and exits **0** when the bundle matches its recorded
provenance; it exits **1** on any drift. **CI runs this verifier on every `push`
and `pull_request`** (a step in
[`.github/workflows/secret-scan.yml`](.github/workflows/secret-scan.yml)), so a
drifted or hand-edited bundle fails the build automatically — the integrity gate
is enforced, not merely available. The bundle is updated **only** via the
re-vendor tooling — never by hand-editing `vendor/ynab-mcp/index.cjs`.

### Upstream provenance

`verify-bundle.sh` proves the committed copy hasn't **drifted**; it does not prove
our copy descends from a **trustworthy** upstream. That link is established at
vendoring time by `bin/revendor.sh`, which refuses to extract a tarball until it
matches the npm registry's published provenance:

- **Integrity** — the downloaded tarball's computed SHA-512 SRI must match the
  registry's `dist.integrity` **and** its SHA-1 must match `dist.shasum`, checked
  *before extraction*. A mismatch aborts the re-vendor.
- **Signature** — the registry's cryptographic signature on the version is
  verified with npm's own published keys (`npm audit signatures`). An invalid
  signature is a hard stop; a missing one is recorded as a residual supply-chain
  risk in the marker, never skipped silently. The audited install is **bound to
  the packed tarball**: its lockfile-recorded integrity (which npm itself
  enforces against the installed bytes) must equal the SRI computed from the
  exact tarball that was integrity-verified and extracted, so the signature
  verdict can never attest different bytes than the committed ones.

The integrity gate re-runs on **every** invocation; only the signature check is
skipped when no new bytes are adopted. Re-running `bin/revendor.sh` against an
already-vendored, unchanged version is a no-op that returns *before* the
signature gate, so a re-pin does **not** re-verify the registry signature — a
signature revoked upstream after the original vendor is not re-checked on a
re-pin. A re-pin is not a re-attestation.

The outcome is recorded in `vendor/ynab-mcp/vendored.json`
(`tarball_integrity`, `tarball_shasum`, `signature_status`), making the full chain
auditable from one file: **registry hash → downloaded tarball → extracted CJS →
committed copy**. The exact commands and pass/fail criteria live in
[`docs/vendoring.md`](docs/vendoring.md#verifying-upstream-provenance).

## Generated Artifacts

The token and the vendored bundle are not the only sensitive surfaces. Every
review run writes **unencrypted, plaintext files** to your local disk that
together contain your **complete financial detail** — transaction history,
balances, payees, category assignments, and tax figures. They are **not
encrypted at rest** by this plugin; their only protection is owner-only file
permissions and the privacy of the machine they live on.

Two guarantees apply to all of them:

- **Owner-only permissions.** Every artifact is written mode **0600** (owner
  read/write only) and every directory the plugin creates is mode **0700**. The
  data directory is created *at creation time* under `umask 077` (`commands/setup.md`,
  `commands/ynab-migrate.md`) so there is never a window in which it is
  world-traversable. Every file artifact is likewise owner-only *from the moment it
  exists*, never by a later `chmod`: `config.json` is staged inside a `umask 077`
  subshell before it is atomically published, the report writer creates a `0600`
  temp file, `bin/audit-log.sh` writes under a `umask 077` subshell, and the
  monitor-state and tax-tracker writers pass an explicit `mode: 0o600`. Each site
  additionally `chmod`s as defense-in-depth, which re-tightens a stale temp file
  from an interrupted run — a second layer, never the only one. `commands/setup.md`
  and `commands/ynab-migrate.md` (the data dir + `config.json`), the `.mjs` state
  writers, `bin/audit-log.sh`, and `bin/report-writer.sh` all enforce this.
- **Not for shared or cloud-synced locations.** The default report directory,
  `~/Documents/Claude/Reports`, sits under `~/Documents`, which **macOS may sync
  to iCloud Drive** when Desktop & Documents syncing is enabled — silently
  uploading your full financial reports to cloud storage. Keep the report and
  data directories on local, disk-encrypted storage (enable **FileVault**), and
  do **not** point `.report.output_dir` at a shared drive, a synced folder, or a
  cloud-backed location unless you intend those records to be copied there.

### Artifact inventory

Every file the plugin generates that contains financial data, where it lives, and
who is responsible for pruning it. `<data-dir>` is the update-stable plugin data
directory, `~/.claude/plugins/data/workbench-ynab-claude-workbench/`.

| Artifact | Path pattern | Contains | Pruning |
|---|---|---|---|
| Review report | `<report-dir>/YNAB-<Tier>-Review-<YYYY-MM-DD>.html` (default `<report-dir>` = `~/Documents/Claude/Reports/`) | Full review: classifications, income/spending, balances, cash-flow, net worth, tax summary — and the proposed change-set ([#53](https://github.com/mike-bronner/workbench-ynab/issues/53)). Accumulates one file per run. | **`bin/ynab-prune.sh`** — retention policy (see below). |
| Write-back audit log | `<data-dir>/audit/audit-<YYYY-MM>.jsonl` | Append-only record of every applied ledger write (categorize / allocate / reconcile / delete-duplicate) with tool + result. | Retained deliberately as the write-back trail — user-managed. |
| Monitor state | `<data-dir>/monitor-state.json` | Latest between-run monitoring snapshot (balances / transaction deltas). | Single live file, overwritten in place — no accumulation. |
| Alert log | `<data-dir>/alert-log.jsonl` | Append-only monitoring alerts. | User-managed. |
| Estimated-tax tracker | `<data-dir>/tax-tracker.json` | Running estimated-tax totals. | Single live file, overwritten in place. |
| Tax profile | `<data-dir>/tax-profile.json` | Your tax configuration (filing status, rates, thresholds). | Live config — removed at uninstall **only if you choose to delete `<data-dir>`**; kept by default. |
| Config | `<data-dir>/config.json` | Budget ids, business/tax/persona/report settings (never the token — that is Keychain-only). | Live config — removed at uninstall **only if you choose to delete `<data-dir>`**; kept by default. |
| Change-set proposals *(future — M4-10)* | `<data-dir>/proposals/changeset-<stamp>.json` (default; override `.apply.proposal_path`) | The pending proposed ledger writes a review emits ([design](assets/changeset-lifecycle.md)). Not written yet — the review write path (**M4-10**) will emit them. | **Not yet swept.** When M4-10 lands it must create these `0600`, add them to this inventory, and give them a retention story (extend `bin/ynab-prune.sh` to `proposals/`), since they accumulate unbounded like reports. |

**Retention & pruning.** Review reports are the one artifact that grows without
bound (once the proposal writer lands, its `proposals/` files will be a second —
see the inventory row above), so [`bin/ynab-prune.sh`](bin/ynab-prune.sh) enforces
a documented retention
policy: it removes report files older than a maximum age (default **30 days**,
overridable per-install via `.report.retention_days` in `config.json` or
per-invocation via `--days N`). It is **dry-run by default** — it previews exactly
what would be deleted and removes nothing unless `--apply` is passed:

```bash
bash bin/ynab-prune.sh              # preview reports older than the threshold
bash bin/ynab-prune.sh --apply      # actually delete them
```

**Uninstall.** The uninstall / teardown flow
([#67](https://github.com/mike-bronner/workbench-ynab/issues/67)) —
`/workbench-ynab:uninstall`, with the by-hand equivalent in
[`docs/uninstall.md`](docs/uninstall.md) — references this inventory so it can
name the correct paths when it asks what to do with your residual financial
data. It prompts before touching `<data-dir>` and **keeps it by default**, since
deleting it destroys the write-back audit trail irreversibly. It never deletes
`<report-dir>`: that path is user-chosen and may hold unrelated files, so
reports stay yours to prune with [`bin/ynab-prune.sh`](bin/ynab-prune.sh).

## Reporting a vulnerability

**Do not open a public GitHub issue for a security vulnerability.** Instead, use
**GitHub private vulnerability reporting**:

1. Go to the repository's **Security** tab →
   **[Report a vulnerability](https://github.com/mike-bronner/workbench-ynab/security/advisories/new)**.
2. Describe the issue, the impact, and reproduction steps. If a YNAB token may
   have been exposed, **rotate it immediately** (see
   [Leaked token remediation](#leaked-token-remediation)) before anything else.

Reports are triaged privately; a fix and coordinated disclosure follow once the
issue is confirmed. Please give a reasonable window to respond before any public
disclosure.

## Leaked Token Remediation

If a YNAB token has ever appeared in a plaintext config or a log, it is
**permanently compromised** and **must be rotated** — scrubbing the on-disk
copies is not enough on its own.

The full rotation ceremony and the on-disk scrub/verify/detect tooling are
documented in **[docs/token-rotation.md](docs/token-rotation.md)**:

- **Rotate** — revoke the compromised token at
  [app.ynab.com → Developer Settings](https://app.ynab.com/settings/developer),
  mint a replacement, and store it in the macOS Keychain.
- **Scrub** — `bin/scrub-leaked-token.sh` redacts every on-disk occurrence of
  the old token across the four known leak surfaces, in place.
- **Verify** — `bin/scrub-leaked-token.sh --verify` confirms zero remaining
  matches and exits non-zero if any are found.
- **Detect** — `bin/scrub-leaked-token.sh --detect` flags a plaintext token
  still present in the Claude Desktop config (the migration hook for #77).
