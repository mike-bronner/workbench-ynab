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
  metachar can never reach the literal substitution.
- The three **scalar slots** are filled by the writer, not the caller: `{{tier}}`
  and `{{report_date}}` from the flags, and `{{output_path}}` from the path the
  writer itself decides (never hardcoded in the template).
- **`~` and `$VAR` / `${VAR}`** in the configured/flag path are expanded (no
  `eval`; command and arithmetic substitution are never executed). Any number of
  **trailing slashes** on the directory is tolerated. A path that expands to
  **empty** (e.g. `.report.output_dir` referencing an unset variable) is
  **refused** — the writer never writes to the filesystem root.
- The directory is created with **`mkdir -p`** before writing (no error if it
  already exists), and both the `mkdir` and the write are checked — a failure
  exits non-zero and prints **no** success path.

On success the writer prints the **absolute path** of the written file to
stdout — a single line, directly usable as `report_path="$(report-writer.sh …)"`.

## Completeness — no partial / silently-empty reports

Every block slot the template declares **must** be supplied. A section with
nothing to report is supplied as the literal **`no findings`**, which the writer
renders as an **empty section** (the surrounding `<section>` stays, per
[`SLOTS.md`](../assets/report/SLOTS.md)). The required set is derived from the
template itself (a scan for `<!-- SLOT:name -->`), so it can never drift from a
hardcoded list here.

If a required slot is **unsupplied or supplied empty** (without the `no findings`
sentinel), the writer prints the offending slot names to stderr and **exits
non-zero without writing any file**. A partial report can never reach the user.
Any **unknown** slot names are reported **alongside** the missing ones, so a
typo (which shows up as both a missing real slot and an unknown name) is always
visible rather than masquerading as a plain "missing slot".

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Report written; the absolute path is on stdout. |
| `1` | A required slot was missing or empty — **no file written**. |
| `2` | Usage error: bad flag, bad `--tier`, bad `--date`, an unknown or invalid slot name, an output dir that resolves to empty, or a missing template. |

## Portability

bash **3.2** compatible (macOS system bash): indexed arrays only (no
associative arrays), no `${x,,}`, no `mapfile`; array expansions are guarded so
`set -u` never trips on an empty array. Needs only `bash`, `jq`, and the
coreutils already required by the plugin.
