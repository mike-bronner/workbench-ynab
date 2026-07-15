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
   `shasum`, `tar`, or `openssl` is missing from `$PATH`.
2. **Download** — runs `npm pack @dizzlkheinz/ynab-mcpb@<version>` into a temp
   directory. Nothing is installed into the repo and the repo root is never
   touched.
3. **Provenance gate — integrity (before extraction)** — cross-checks the
   download against the npm registry's *published* integrity metadata
   (`npm view … dist.integrity dist.shasum`). The tarball's computed **SHA-512
   SRI** must match `dist.integrity` **and** its computed **SHA-1** must match
   `dist.shasum`. Either mismatch aborts the run *before a single byte is
   unpacked* — the bytes we would vendor must descend from the registry-published
   artifact. (See [Verifying upstream provenance](#verifying-upstream-provenance).)
4. **Provenance gate — signature** — verifies the registry's cryptographic
   signature on the version with npm's own published keys (`npm audit
   signatures`), in an isolated temp install (never the repo). An **invalid**
   signature is a hard stop (possible tampering); a **missing** signature is
   recorded in the marker as a residual supply-chain risk, never skipped
   silently. The gate is **fail-closed**: `verified` is recorded only when the
   audit output is a shape it fully recognizes (an object with `invalid` and
   `missing` arrays and no other keys). Anything else — non-JSON noise, null
   fields, or a *new* failure category a future npm might add — aborts the run
   rather than passing, so an unexpected shape can never be mistaken for a clean
   signature.
5. **Extract** — copies `dist/bundle/index.cjs` from the unpacked tarball over
   `vendor/ynab-mcp/index.cjs`.
6. **Re-hash + rewrite the marker** — recomputes the SHA-256 of both the
   upstream tarball and the newly written bundle, and rewrites
   [`vendor/ynab-mcp/vendored.json`](../vendor/ynab-mcp/vendored.json) with the
   package, version, both hashes, the registry SHA-1, today's date, the registry
   URL + integrity, and the signature-verification outcome.
7. **Summary + reminder** — prints an `old → new` diff summary and reminds you
   to run the offline-boot verification before committing.
8. **Cleanup** — removes the temp directory on exit (including on error).

The script is **idempotent**: re-running with a version whose bundle bytes are
already vendored prints a `No change` line and exits `0` without modifying any
file. **Carve-out:** the no-change path returns *before* the signature gate, so
re-pinning an unchanged version does **not** re-verify the registry signature — a
signature revoked upstream after the original vendor is not re-checked on a re-pin.
Force a fresh attestation by re-vendoring changed bytes (a new version or
republished bundle).

> **The script never commits.** It updates the working tree only. You review the
> diff and commit manually — the same commit-approval gate that governs every
> change in this repo. The bundle is large, so expect `index.cjs` and
> `vendored.json` to be the only files in the diff.

## Verifying upstream provenance

> **Why this gate exists (GAP-2 / [#5](https://github.com/mike-bronner/workbench-ynab/issues/5)).**
> `vendor/ynab-mcp/index.cjs` is the only code that touches the YNAB API with
> full read/write authority, so a compromised upstream is a full credential +
> ledger compromise. The bundle/tarball SHA-256s prove *our committed copy hasn't
> drifted* — they do **not** prove our copy descends from a **trustworthy**
> upstream. This gate links the chain to the registry:
> **registry-published hash → downloaded tarball → extracted CJS → committed copy.**

`bin/revendor.sh` runs every step below automatically and aborts on any failure.
This section documents the exact commands so the gate is **reproducible by hand**
on a future version bump — run them yourself if you ever need to audit a vendored
version or debug a script failure. Substitute the target `<spec>`
(`@dizzlkheinz/ynab-mcpb@<version>`) throughout.

### Step 1 — record the registry's published metadata

```sh
npm view @dizzlkheinz/ynab-mcpb@0.26.10 dist.integrity dist.shasum dist.tarball
```

Expected output shape (three values — record all three):

```
dist.integrity = 'sha512-pkUQFtVRPhAjfK0APDCdA6wY3y8mAsBc60pn/KQAgAPgN6iWBD27NmxIa3wym6pitiMUl1Ib7h82a4znlJn4KQ=='
dist.shasum = '331850bd58f096bfeb024ae4cc9a238a881d7cc1'
dist.tarball = 'https://registry.npmjs.org/@dizzlkheinz/ynab-mcpb/-/ynab-mcpb-0.26.10.tgz'
```

**Pass criterion:** all three values are returned. An empty `dist.integrity` or
`dist.shasum` is a **fail** — the gate cannot proceed.

### Step 2 — verify the downloaded tarball's integrity (before extraction)

Download the tarball, then compute its hashes and compare them to Step 1:

```sh
TGZ=$(npm pack --json @dizzlkheinz/ynab-mcpb@0.26.10 | jq -r '.[0].filename')

# Computed SHA-512 SRI — must equal dist.integrity:
printf 'sha512-%s\n' "$(openssl dgst -sha512 -binary "$TGZ" | openssl base64 -A)"

# Computed SHA-1 shasum — must equal dist.shasum:
shasum -a 1 "$TGZ" | awk '{print $1}'
```

**Pass criterion:** the computed SHA-512 SRI is **byte-identical** to
`dist.integrity` **and** the computed SHA-1 is **byte-identical** to
`dist.shasum`. Either mismatch is a **fail** — the download does not descend from
the registry-published artifact; **do not extract or commit it.**

### Step 3 — verify the registry signature / provenance

```sh
work=$(mktemp -d) && cd "$work"
printf '{"name":"sigcheck","version":"0.0.0","private":true}\n' > package.json
npm install --ignore-scripts --no-audit --no-fund @dizzlkheinz/ynab-mcpb@0.26.10
npm audit signatures
```

Expected output for a signed package:

```
<N> packages have verified registry signatures
<M> packages have verified attestations
```

**Pass criteria:**

- **verified** — `@dizzlkheinz/ynab-mcpb` reports a verified registry signature.
  Record `"signature_status": "verified"` in the marker.
- **invalid** — `npm audit signatures` reports an *invalid* signature for the
  package. This is a **hard fail** (possible tampering): **do not vendor.**
- **unavailable** — the registry publishes **no** signature for the package
  (`found no dependencies to audit…`, or the package appears under `missing`).
  This is **not** a silent skip: record `"signature_status": "unavailable"` plus
  a `"signature_note"` documenting the residual supply-chain risk in the marker.
- **unrecognized output** — if `npm audit signatures --json` emits anything the
  gate can't fully parse (non-JSON noise, `null` in place of the `invalid` /
  `missing` arrays, or a new failure category beyond those two), the script
  **aborts fail-closed** rather than recording `verified`. Re-run after
  confirming your npm is current; if the shape genuinely changed upstream, update
  `bin/revendor.sh`'s schema guard before trusting the result.

### Step 4 — record the outcome in the marker

The script writes [`vendor/ynab-mcp/vendored.json`](../vendor/ynab-mcp/vendored.json)
with `tarball_integrity` (the registry SRI), `tarball_shasum` (the registry
SHA-1), and `signature_status` / `signature_method` (+ `signature_note` when
unavailable). Together with the existing `tarball_sha256` and `bundle_sha256`,
the marker is the single auditable record of the full provenance chain.

> **`@dizzlkheinz/ynab-mcpb@0.26.10` — verified.** This procedure was executed
> against the pinned version: SHA-512 SRI and SHA-1 both match the registry, and
> the registry signature verified against npm's published keys
> (`signature_status: "verified"`). The outcome is recorded in the marker.

## The Node floor

`vendor/ynab-mcp/NODE_VERSION` pins the minimum Node **major** the vendored
bundle supports (issue #3) — a single bare integer, the one canonical value
every enforcement point reads:

- **`bin/node-floor.sh`** compares `node --version` against it and fails with
  one actionable STDERR line (`workbench-ynab requires Node >= X; you have Y —
  upgrade via …`). Both `/workbench-ynab:setup` (Step 1a) and `bin/launcher.sh`
  run it, so interactive setup *and* scheduled runs fail fast instead of
  letting the bundle die cryptically mid-boot.
- **CI** (`.github/workflows/ci.yml`) runs the `test` job on both the floor
  major and current LTS; the floor lane boots the bundle (the offline-boot
  proof) on exactly that major.
- **`tests/unit/node-floor.test.sh`** keeps the copies honest: the CI matrix
  entry and the README's documented floor must match the canonical file, or
  the suite fails.

The floor was derived from the bundle's dependency chain (the strongest
declared constraint is `@modelcontextprotocol/sdk`'s `engines.node >=18`;
upstream `@dizzlkheinz/ynab-mcpb` declares no `engines` field) and confirmed
empirically by booting the vendored `index.cjs` on candidate majors.

**Re-vendoring re-derives it**: `bin/revendor.sh` reads the incoming package's
`engines.node` (when declared) and raises `NODE_VERSION` if the requirement
moved up — never lowers it automatically. When upstream declares no engines
field the floor is kept, and the CI floor lane remains the proof that the new
bundle still boots on it. After any bump, update the README bullet and the CI
matrix entry — `tests/unit/node-floor.test.sh` fails until they agree.

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
| `tarball_shasum` | SHA-1 of the upstream tarball — the registry's `dist.shasum`, cross-checked at vendoring time. |
| `bundle_sha256` | SHA-256 of the vendored `index.cjs` — the drift guard. |
| `date_vendored` | UTC timestamp of the re-vendor (`YYYY-MM-DDTHH:MM:SSZ`). |
| `tarball_url` | Registry URL the tarball came from (the registry's `dist.tarball`). |
| `tarball_integrity` | The registry's published SRI (`dist.integrity`), verified against the downloaded tarball. |
| `signature_status` | Registry-signature outcome: `verified` or `unavailable`. |
| `signature_method` | How the signature was checked (`npm audit signatures`). |
| `signature_note` | Present only when `signature_status` is `unavailable` — documents the residual supply-chain risk. |
| `bundle_source_path` | Path to the bundle inside the unpacked tarball. |
| `vendored_path` | Where the bundle lives in this repo. |
| `self_contained` | Asserts the bundle boots with no `node_modules` (proven by the offline-boot test, not by this script). |

This marker is **frozen, provenance-only** — release automation never touches
it (it bumps only `.claude-plugin/plugin.json`). It changes solely when the
bundle is deliberately re-vendored with this script.
