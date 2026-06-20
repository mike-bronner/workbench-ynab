# YNAB Token Rotation & Leaked-Token Remediation

> **Rotation is mandatory, not optional.** The moment a YNAB Personal Access
> Token appears in *any* plaintext config or log — the Claude Desktop config, a
> session log, a project transcript, a tool-result cache — that token is
> **permanently compromised**. A YNAB token grants full read/write access to
> your budget. You cannot "un-leak" a secret; the only safe response is to
> revoke it and mint a new one. Scrubbing the on-disk copies (below) is
> necessary cleanup, but it is **not** a substitute for rotation.

This document covers two things:

1. **Rotation** — revoke the compromised token and mint + store a replacement.
2. **Scrub** — redact the leaked value from the on-disk artifacts it reached.

Do them **in that order**: rotate first (so the leaked value is already dead),
then scrub.

---

## 1. Rotate the token

### Step 1 — Revoke the compromised token

1. Sign in at <https://app.ynab.com>.
2. Open **Account Settings → Developer Settings**
   (<https://app.ynab.com/settings/developer>).
3. Under **Personal Access Tokens**, find the compromised token and click
   **Revoke**. Once revoked it can never be used again — this is the step that
   actually neutralizes the leak.

### Step 2 — Mint a replacement

1. Still under **Developer Settings → Personal Access Tokens**, click
   **New Token**.
2. Re-enter your password if prompted and copy the new token value. YNAB shows
   it **once** — if you lose it, revoke it and mint another.

### Step 3 — Store the new token in the macOS Keychain

This plugin reads the token from the macOS Keychain — **never** from a config
file, an environment variable, or this repo. Store the new value:

```sh
security add-generic-password \
  -s "ynab-mcp" \
  -a "access-token" \
  -w "$NEW_TOKEN" \
  -U
```

- `-s "ynab-mcp"` — the service name the launcher looks up.
- `-a "access-token"` — the account name.
- `-w "$NEW_TOKEN"` — the secret. Put the value in the `NEW_TOKEN` shell
  variable first (e.g. `read -rs NEW_TOKEN`) so it is **not** captured in your
  shell history.
- `-U` — update the entry in place if one already exists, instead of erroring.

> **Never** paste the token directly on the command line as a literal — that
> writes it straight into your shell history. Read it into a variable with
> `read -rs` first.

Verify it stored (this prints the secret, so do it only in a private shell):

```sh
security find-generic-password -s "ynab-mcp" -a "access-token" -w
```

---

## 2. Scrub the leaked value from disk

After rotating, redact the **old** (now-revoked) token from the artifacts it
leaked into. Use the bundled scrubber:

```sh
bin/scrub-leaked-token.sh
```

It prompts for the old token with hidden input (`read -rs`) — **never** pass the
token as an argument or an environment variable — and redacts every occurrence
of it, in place, across the four known leak surfaces:

| # | Surface | Path |
|---|---------|------|
| 1 | Session logs        | `~/Documents/Claude/Memory/sessions/**/*.log.md` |
| 2 | Project transcripts | `~/.claude/projects/**/*.jsonl` |
| 3 | Tool-result caches  | `~/.claude/projects/**/tool-results/*.txt` |
| 4 | Desktop config      | `~/Library/Application Support/Claude/claude_desktop_config.json` (token value only) |

Each occurrence is replaced in place with `[YNAB-TOKEN-REDACTED]`. No backup
file is written and no file is deleted, so nothing on disk retains the secret.
The scrubber prints a per-surface count of files scanned and modified and
**never** prints the token itself.

> Removing the legacy `ynab` connector block from the Desktop config is a
> separate step handled by the migration command (#77). The scrubber only
> redacts the token *value*; it preserves the `mcpServers.ynab` structure.

### Verify the scrub

Confirm zero remaining matches across all four surfaces **and** the git-tracked
repo tree:

```sh
bin/scrub-leaked-token.sh --verify
```

It re-prompts for the old token (hidden input), prints the remaining match count
per surface, and **exits non-zero if any match is found**. A clean run reports
all zeros and exits `0`.

### Detect a plaintext token (migration hook)

To check whether the Desktop config still holds a plaintext token before
retiring the old connector:

```sh
bin/scrub-leaked-token.sh --detect
```

It inspects `mcpServers.ynab.env.YNAB_ACCESS_TOKEN` in the Desktop config,
warns (with a link back to this document) and **exits non-zero** if a plaintext
token is present, and exits `0` otherwise. The migration command (#77) invokes
this before offering to remove the legacy connector.

---

## Why this happened (and how it's prevented going forward)

The legacy standalone YNAB connector stored its token **in plaintext** in the
Claude Desktop config, so every process that read or logged that config — and
every session that referenced it — copied the secret onto disk. This plugin
stores the token in the macOS Keychain instead, and the launcher reads it from
there at runtime, so the value never lands in a config file or a log. See
`SECURITY.md` for the repo-wide secret-hygiene posture.
