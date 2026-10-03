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

## Headless against the same packages: use logoscore's portable bundle

`scripts/eth-rpc-logoscore-test.sh` runs a logoscore daemon over a profile's installed
modules. A plain `logos-logoscore-cli#cli` build is a **dev** host: it refused every
catalog package ("installed for variant 'linux-amd64' which is not supported on this
platform … supported variants [linux-x86_64-dev, …]"), so nothing but the bundled
modules loaded and every muster call answered empty. `#cli-bundle-dir` is the portable
build and loads them. Same rule as the AppImage: portable packages need a portable host.

Result (2026-10-03): muster seeds eth_rpc_module's registry, a USDC read on Ethereum
through muster's own URL fails with "your RPC does not serve eip155:1", and the same read
through eth_rpc_module answers `USDC`, 6 decimals; `settings()` reports the platform.

## R1 on display: account, link, signer (2026-10-03)

The whole hand-off loop, on the release, nothing seeded:

1. Settings' keystore row: "attested as muster_module; no accounts yet". **Create or import an
   account** raises `evm.accounts.manage`; Basecamp asks "Muster wants to evm.accounts.manage"
   and opens `evm_keystore_ui` (the custodian). A hand-off: the shell stays there.
2. In the keystore app: Create → a 12-word phrase, words 1/5/12 confirmed, a vault password.
3. Back in Muster: "attested as muster_module; 1 account; approvals by evm_signer_ui".
   **Use for approvals** → `keystore_select` asks keystore_module for the F-14 binding.
4. The view's escort sees the new waiting request and raises `evm.signing.approve {handle}`;
   Basecamp asks, then opens `evm_signer_ui`, which shows "Requested by: muster_module",
   the purpose as the requester's claim, and the opaque digest with "This signer cannot show
   you what this authorises" (the interim cost exo-149.6 removes).
5. Vault password → Approve. The shell returns to Muster by itself; muster's pump fetches the
   signature, checks it recovers to the account over muster's own hash, and stores the
   binding: "Approvals go through the selected account, linked to your Muster identity."

**Found on the way:** the account row was one `RowLayout` holding a fill-width, elided address
and the "Use for approvals" button. Inside Basecamp the button (and anything else after the
address in that row) never drew, with no QML warning. Each account is now a `ColumnLayout`:
the address, then the button on its own line. Also: Basecamp's sidebar order of installed apps
changes between launches; find an app by its tab title, not a fixed slot.

## R4 headless: a split paid through tx_sender_module (2026-10-03)

`scripts/split-platform-logoscore-test.sh`: two muster instances, each in its own logoscore
0.3.1 daemon (portable bundle) over a Basecamp profile's modules plus the catalog's
`evm_keystore_cli` / `evm_signer_cli` (the person, headless), peered on a local delivery pair,
against anvil. Each person's eth_rpc_module names the anvil as chain 31337 (a testnet), each
person's key is imported into their own keystore_module, selected in muster, and linked.
Alice proposes 0.002 ETH on eip155:31337; Bob agrees, then pays: muster derives the call,
tx_sender prepares it, the legs match, send; the signer shows "Requested by:
tx_sender_module … Pay my share of 'anvil dinner', agreed in a Muster room [asked by
muster_module]" and one transaction on chain 31337; one approval; Bob's pump polls
send_status (the broadcast), his report names the hash, Alice's own eth_rpc_module read
confirms, **final on both, Alice +1000000000000000 wei exactly**, and tx_sender's history
row carries origin muster_module and the intent in its meta. PASS.

Harness lessons: `logoscore call` turns a decimal argument into a number, so a `tstr` total
needs `str:`; `coordinate_pending` answers objects (`{identity, alias, bindsOwner}`); a
joiner's grant arrives when its session polls (the UI's intents tick), so a headless wait
loop ticks both instances; Alice's delivery node starts at her first `coordinate_join`, so a
local peer dials her only after it.

The same script's second half (2026-10-03, PASS): the real Safe v1.4.1 on that anvil
(`infra/anvil/devnet.sh`, owners anvil 0/1/2, 2 of 3), funded; Alice discloses it and sets
the room's policy; a Safe intent pays anvil 3 0.001 ETH. Each owner contributes with no key
ref: routed to their selected keystore account (`auto`, a test chain), approved in the
signer, published: collecting → executable. Alice's `coordinate_submit` answers
`onchain: awaiting-approval` with her keystore account as relayer; the execTransaction goes
through tx_sender_module (one approval); the pump publishes submitted and final with the
hash; **final on both, the recipient +1000000000000000 wei exactly.**
