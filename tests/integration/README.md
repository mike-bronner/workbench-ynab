# `tests/integration/`

Integration tests exercise the plugin's real moving parts end-to-end — the
vendored MCP boot, the launcher, the Keychain read — rather than a single pure
function.

## What lands here

- **`offline-boot.sh`** — the M1-7 offline-boot proof (issue #14). It launches
  `node vendor/ynab-mcp/index.cjs` with **no `node_modules` present** and a
  sentinel `YNAB_ACCESS_TOKEN`, completes the MCP `initialize` + `tools/list`
  handshake on stdout, and asserts no `MODULE_NOT_FOUND`. It is a `*.test.sh`
  by another name: name it `offline-boot.test.sh` so `scripts/test.sh` and CI
  (issue #16) discover and run it automatically.

> Note on the path: issue #14 loosely refers to `test/offline-boot.sh`. The
> canonical location established by this harness (issue #4) is
> `tests/integration/offline-boot.test.sh`. Use the canonical path; see
> `docs/testing.md` → "Path map for downstream issues".

Integration tests follow the same bash convention as unit tests: `#!/usr/bin/env
bash`, `set -euo pipefail`, source `tests/lib/assert.sh`, define `test_*`
functions, call `run_tests`. See `docs/testing.md`.
