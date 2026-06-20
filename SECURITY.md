<!--
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ MERGE-ORDER COORDINATION — read before editing                            │
  │                                                                            │
  │ This SECURITY.md was created by PR for issue #73 (leaked-token             │
  │ remediation) and is intentionally MINIMAL: it carries only the            │
  │ "Leaked Token Remediation" section required by #73's acceptance criteria. │
  │                                                                            │
  │ Issue #72 ("Add SECURITY.md and enforce repo-level secret hygiene +       │
  │ bundle integrity") owns the FULL security policy — vulnerability          │
  │ reporting, supported versions, secret-hygiene enforcement, bundle         │
  │ integrity. When #72 lands, MERGE its content around this section; do NOT  │
  │ delete the "Leaked Token Remediation" section or the link to              │
  │ docs/token-rotation.md below. Whichever PR merges second should rebase    │
  │ and fold the two together rather than overwrite.                          │
  └───────────────────────────────────────────────────────────────────────────┘
-->

# Security Policy

> **Status:** placeholder pending #72. The full security policy (vulnerability
> reporting, supported versions, secret-hygiene enforcement, bundle integrity)
> is tracked in issue #72. The section below is the minimum required by #73 and
> must survive the merge with #72.

## Secrets never live on disk

Your YNAB Personal Access Token is stored in the **macOS Keychain** (service
`ynab-mcp`, account `access-token`) and read at runtime. It is never committed
to this repo, written to a config file, or logged. See the `README.md`
"Privacy & safety" section for the user-facing summary.

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
