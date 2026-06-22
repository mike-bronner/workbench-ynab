# Vendoring the YNAB MCP bundle

> **The bundle is the frozen copy of record.** `vendor/ynab-mcp/index.cjs` is a
> self-contained build of [`@dizzlkheinz/ynab-mcpb`](https://www.npmjs.com/package/@dizzlkheinz/ynab-mcpb)
> checked into git on purpose. Boot is **offline, frozen, and reproducible**:
> a given `workbench-ynab` commit always runs against the exact MCP bundle it
> was tested with — no `npx`-on-demand, no floating dependency, no
> `node_modules` install step. **Never edit `index.cjs` by hand.** It changes
> only through the re-vendor script described here.

## Why vendor at all

The vendored MCP is the only thing that talks to the YNAB API (see the
architecture diagram in the [README](../README.md)). Pinning it in git instead
of installing it at runtime buys three guarantees:

- **Offline + reproducible boot** — the server starts on system `node` with no
  network and no dependency resolution. The [`offline-boot` proof](../tests/integration/offline-boot.test.sh)
  (M1-7) asserts this on every PR.
- **Supply-chain control** — the exact bytes that ship are reviewable in a diff,
  and their provenance (version, hashes, source URL) is recorded alongside them.
- **Version lock-step** — the plugin and the bundle move together, so a commit
  is never paired with an MCP build it wasn't tested against.

Identity is the **artifact hash**, not just the version string: a version
republished upstream with different bytes is detected as a real change.

## Updating to a new version

Re-vendoring is one command — `bin/revendor.sh`:

```sh
# Vendor a specific version:
bin/revendor.sh 0.27.0

# Or re-check the currently-pinned version (re-pull + re-hash):
bin/revendor.sh
```

What it does, end to end:

1. **Prereq check** — hard-errors with guidance if `node`, `npm`, `jq`,
   `shasum`, or `tar` is missing from `$PATH`.
2. **Download** — runs `npm pack @dizzlkheinz/ynab-mcpb@<version>` into a temp
   directory. Nothing is installed into the repo and the repo root is never
   touched.
3. **Extract** — copies `dist/bundle/index.cjs` from the unpacked tarball over
   `vendor/ynab-mcp/index.cjs`.
4. **Re-hash + rewrite the marker** — recomputes the SHA-256 of both the
   upstream tarball and the newly written bundle, and rewrites
   [`vendor/ynab-mcp/vendored.json`](../vendor/ynab-mcp/vendored.json) with the
   package, version, both hashes, today's date, and the registry URL +
   integrity.
5. **Summary + reminder** — prints an `old → new` diff summary and reminds you
   to run the offline-boot verification before committing.
6. **Cleanup** — removes the temp directory on exit (including on error).

The script is **idempotent**: re-running with a version whose bundle bytes are
already vendored prints a `No change` line and exits `0` without modifying any
file.

> **The script never commits.** It updates the working tree only. You review the
> diff and commit manually — the same commit-approval gate that governs every
> change in this repo. The bundle is large, so expect `index.cjs` and
> `vendored.json` to be the only files in the diff.

## Verifying the result

After a re-vendor, **always** run the offline-boot proof before committing — it
is the load-bearing check that the new bundle is genuinely self-contained and
boots on bare `node`:

```sh
scripts/test.sh tests/integration/offline-boot.test.sh
```

You can also run the cheaper on-disk integrity check, which asserts the
committed bundle still matches its recorded marker hash and that the shim is in
place:

```sh
vendor/ynab-mcp/verify-bundle.sh
```

If the offline-boot proof fails, the new bundle is **not** self-contained — do
not commit it. A failed run writes its captured output to
`tests/integration/offline-boot-failure.txt` as evidence.

## The version-marker format

`vendor/ynab-mcp/vendored.json` is the provenance record for the frozen bundle.
The re-vendor script writes it; `verify-bundle.sh` reads `bundle_sha256` to
detect drift.

| Field | Meaning |
|---|---|
| `name` | npm package name (`@dizzlkheinz/ynab-mcpb`). |
| `version` | The vendored upstream version. |
| `tarball_sha256` | SHA-256 of the upstream npm tarball that was unpacked. |
| `bundle_sha256` | SHA-256 of the vendored `index.cjs` — the drift guard. |
| `date_vendored` | UTC timestamp of the re-vendor (`YYYY-MM-DDTHH:MM:SSZ`). |
| `tarball_url` | Registry URL the tarball came from. |
| `tarball_integrity` | npm's SRI integrity hash for the tarball. |
| `bundle_source_path` | Path to the bundle inside the unpacked tarball. |
| `vendored_path` | Where the bundle lives in this repo. |
| `self_contained` | Asserts the bundle boots with no `node_modules` (proven by the offline-boot test, not by this script). |

This marker is **frozen, provenance-only** — release automation never touches
it (it bumps only `.claude-plugin/plugin.json`). It changes solely when the
bundle is deliberately re-vendored with this script.
