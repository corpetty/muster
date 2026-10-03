# Muster in the Basecamp 0.3.1 release

**exo-d4d.1 (R0), 2026-10-03. Status: WORKS.** Muster installs into the released Basecamp
0.3.1 AppImage beside the default catalog's EVM stack, renders, boots its delivery node, and
`keystore_module` attributes its calls to `muster_module`. Reproduce with
`scripts/basecamp-profile.sh <name> --fresh --xvfb :97`.

## What was run

- **Host:** `LogosBasecamp-Desktop-v0.3.1-aeb819-x86_64.AppImage`, extracted, with
  `--user-dir` for an isolated profile, on Xvfb (`QT_QPA_PLATFORM=xcb
  QT_QUICK_BACKEND=software`). The recipe is in `qml-errors-are-invisible-to-nix-build.md`.
- **Catalog packages first.** 13 of them, from the catalog's own release URLs, each
  checked against its sha256 (`infra/basecamp/catalog-0.3.1.tsv`): `keystore_module`,
  `evm_signer_ui`, `evm_keystore_ui`, `eth_rpc_module`, `eth_rpc_ui`, `tx_sender_module`,
  `fee_module`, `token_list_module`, `verified_proxy_module`, `delivery_module` 0.3.0,
  `lez_core` 0.5.0, and the two RLN modules. A local install resolves no dependencies, so
  these go in first.
- **Then muster.** `.#lgx-portable` for `module/` and `ui/`, installed with portable `lgpm`
  (logos-package-manager@3133786e, the one the release links).

## What it saw

| Check | Result |
|---|---|
| H1 `muster_module` loads (protocol-0.2 glue, 7 exports, beside 0.9 modules) | yes |
| H2 `muster_ui` renders (UI builder `4717b9af`, July) | **yes**: Home, Room, Account, Walkthrough, Settings, Contacts, Send all draw |
| H2' the UI re-pinned to builder `0.3.1` (`16e2f6bd`) | yes, the same (exo-eb6.6) |
| H3 the portable packages install | yes, all 15 |
| H4 `keystore_module.caller_identity()` from muster | **`module muster_module`**, approver set. Settings reads "attested as muster_module; no accounts yet", with the remedy pointing to `evm_keystore_ui` |
| delivery | `delivery_module` 0.3.0 boots from muster's start-inbox call, finds 10 `logos.dev` peers by service discovery, and answers muster's store queries |

So the worry that the July UI builder would leave the view blank in the 0.3.1 ui-host
(the atlas's compatibility rule 4) did not come true for this release. The re-pin is still
worth doing: it keeps the UI on the host's generation for the next release. It changes the
standalone runner too, so it waits on `scripts/ui-parity.sh`.

## The one wall: a module nobody declares never starts

`eth_rpc_module` was installed but had no `module_data` directory: Basecamp had never
started it. Basecamp starts a core module only when something that is loaded declares it as
a dependency, and muster did not. So muster's `evm-chains = auto` found no platform
registry and fell back to its own RPC URL, which is the designed fallback, silently.

Fix: `eth_rpc_module` joins `module/metadata.json`'s dependencies, the builder's flake
inputs, and the runner's module set, the way `keystore_module` did (exo-149.1).

**Rule:** a module muster calls over `lp_*` must be in `dependencies`, or under Basecamp it
is not running. Under `--access-policy enforce` it would also be denied.

## Noise in the log (not muster's)

- `logos.basecamp.sandbox: Redirected Logos.Controls probe away from plugin tree …`: Basecamp
  serves the shared `Logos.*` QML modules itself, not the copy inside the plugin.
- `Main.qml:771 Unable to assign [undefined] to QColor` and `Room.qml:2106 … to int`: theme
  tokens the release's `Logos.Theme` does not define. They are worth a pass, but every
  surface still draws.
