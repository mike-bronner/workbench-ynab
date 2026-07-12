# `bin/report-writer.sh` — the report assembly + output-path contract

`bin/report-writer.sh` is the **single place** the full YNAB review report HTML is
assembled. The universal review skill
([`skills/review/ynab-review.md`](../skills/review/ynab-review.md)) emits
**fragments**; it never regenerates the report chrome. This writer stitches the
frozen, canonical template ([`assets/report/template.html`](../assets/report/template.html),
issue #42) together with those fragments and writes the result to the configured
output directory. Centralising assembly here is the locked anti-pattern fix: the
template stays a constant, the skill produces only the variable content, and the
chrome is never re-emitted per run.

## Why a helper, not inline in the skill

The skill is a markdown protocol. The deterministic parts — path resolution,
slot completeness enforcement, and the literal string-stitch — belong in a
**testable shell unit**, exactly as persona-name resolution lives in
[`bin/persona.sh`](../bin/persona.sh) and config reads in
[`bin/config.sh`](../bin/config.sh). `tests/unit/report-writer.test.sh` is the
regression guard.

## Output directory — configurable, outside-repo, update-surviving

The save directory is read from **`.report.output_dir`** in the user's
[`config.json`](config-schema.md), which lives **outside the repo** at

```
$HOME/.claude/plugins/data/workbench-ynab-claude-workbench/config.json
```

so it **survives plugin updates** — the same data-dir guarantee the whole config
relies on. It is read through `bin/config.sh`'s `_cfg`, i.e. the
`jq -r '.report.output_dir // empty'` idiom mirrored from
`workbench-core/hooks/mcp-memory.sh`, with the **shell default applied at the call
site**. When the field is absent or empty, the shipped default
`~/Documents/Claude/Reports` applies (the prototype's original location, SKILL.md
line 143).

> **Field path note.** The configurable directory is the nested
> `.report.output_dir`, **not** a flat top-level `report_output_dir`. The config
> schema's top level is `additionalProperties: false`, the `report` object was
> added for exactly this purpose, and the loader + review skill already read
> `.report.output_dir` — so the writer uses that one path everywhere.

The template path is resolved the same way: `--template` flag →
`.report.template_path` → the bundled `assets/report/template.html`.

## Usage

```bash
report-writer.sh \
  --tier   <Weekly|Monthly|Quarterly-Tax|Annual> \
  --date   <YYYY-MM-DD> \
  [--template   <path>]      # default: .report.template_path, else bundled asset
  [--output-dir <dir>]       # default: .report.output_dir, else ~/Documents/Claude/Reports
  --slot   <name>=<html>     # repeatable: ONE per block slot the template declares
  …
```

- **`--slot name=value`** is split on the **first** `=`, so a fragment value may
  itself contain `=` (HTML attributes are fine). One `--slot` per block slot in
  [`assets/report/SLOTS.md`](../assets/report/SLOTS.md). The **name** is validated
  at parse time — only lowercase letters, digits, and hyphens — so a glob
  metachar can never reach the literal substitution. Supply each block slot
  **exactly once**: a **duplicate** `--slot name` is a usage error (rather than
  silently keeping the first value and dropping the rest).
- The three **scalar slots** are filled by the writer, not the caller: `{{tier}}`
  and `{{report_date}}` from the flags, and `{{output_path}}` from the path the
  writer itself decides (never hardcoded in the template). All three are
  **HTML-escaped** before substitution — the writer owns escaping the scalars it
  injects — and are substituted **before** the block fragments, so a fragment
  whose own text happens to contain `{{output_path}}` / `{{tier}}` /
  `{{report_date}}` is left intact rather than silently overwritten. `{{tier}}`
  renders the **friendly display form**: the `Quarterly-Tax` enum shows as
  `Quarterly Tax` in the report body while the filename keeps the hyphen
  (`YNAB-Quarterly-Tax-Review-…`).
- **`~` and `$VAR` / `${VAR}`** in the configured/flag path are expanded (no
  `eval`; command and arithmetic substitution are never executed; `$VAR`
  expansion is transitive — a value that itself contains `$OTHER` expands too).
  Any number of **trailing slashes** on the directory is tolerated. A path that
  expands to **empty** (e.g. `.report.output_dir` referencing an unset variable)
  — or to the bare filesystem **root `/`** — is **refused**; the writer never
  writes to the filesystem root. A **relative** resolved directory is made
  absolute against the current working directory, so the emitted path is always
  absolute.
- The directory is created with **`mkdir -p`** before writing (no error if it
  already exists). The report is written to a **temp file in the destination dir
  and `mv`'d into place** — an atomic swap, so a failed same-day rerun (same
  tier+date → same path) never destroys a prior good report and a
  partially-written file is never observable at the final path. Every step
  (`mkdir`, the write, the `mv`) is checked; a failure exits non-zero and prints
  **no** success path.

On success the writer prints the **absolute path** of the written file to
stdout — a single line, directly usable as `report_path="$(report-writer.sh …)"`.

## Completeness — no partial / silently-empty reports

Every block slot the template declares **must** be supplied. A section with
nothing to report is supplied as the literal **`no findings`**, which the writer
renders as an **empty section** (the surrounding `<section>` stays, per
[`SLOTS.md`](../assets/report/SLOTS.md)). The required set is derived from the
template itself (a scan for `<!-- SLOT:name -->`), so it can never drift from a
hardcoded list here. A **malformed** `<!-- SLOT:` marker (unclosed, or a name
outside `[a-z0-9-]`) is rejected as a **usage error before any write** — every
`<!-- SLOT:` opener must be a well-formed `<!-- SLOT:name -->` marker — so a
corrupt template can never produce a silently-wrong report.

If a required slot is **unsupplied or supplied empty** (without the `no findings`
sentinel), the writer prints the offending slot names to stderr and **exits
non-zero without writing any file**. A **whitespace-only** value (`"   "`) is
trimmed first and counts as empty, so it is rejected the same way — it can never
render a silently-blank section. A partial report can never reach the user.
Any **unknown** slot names are reported **alongside** the missing ones, so a
typo (which shows up as both a missing real slot and an unknown name) is always
visible rather than masquerading as a plain "missing slot".

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Report written; the absolute path is on stdout. |
| `1` | A required slot was missing or empty — **no file written**. |
| `2` | Usage error: bad flag, bad `--tier`, an out-of-range or malformed `--date`, an unknown, invalid, or **duplicate** slot name, an output dir that resolves to empty or to the filesystem root `/`, or a **missing or malformed** template. |

## Portability

bash **3.2** compatible (macOS system bash): indexed arrays only (no
associative arrays), no `${x,,}`, no `mapfile`; array expansions are guarded so
`set -u` never trips on an empty array. Needs only `bash`, `jq`, and the
coreutils already required by the plugin.
