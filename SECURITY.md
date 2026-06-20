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
   is scanned for the unambiguous secret shapes. Bundle *integrity* verification
   is a **complementary** control, not a substitute for this scan:
   `verify-bundle.sh` detects drift, not secret content (see
   [Bundle integrity](#bundle-integrity)). The scanner is itself covered by a
   negative test, [`tests/secret-scan.test.sh`](tests/secret-scan.test.sh), which
   proves a synthetic, token-shaped string makes the scan exit non-zero — without
   ever committing such a string.

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
