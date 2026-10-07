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

## R5 on display: a fresh install shows nothing seeded (2026-10-03)

`scripts/basecamp-profile.sh fresh --fresh --xvfb :95`, nothing set: Home reads **Set up an
Ethereum account** ("Your keys live in the Logos keystore, not in Muster…") with the hand-off
button; Settings shows **Ethereum chains · from your device's chain settings** with **Open
chain settings** (`evm.rpc.configure` → `eth_rpc_ui`) in place of muster's own RPC field; the
Account view lists only Hoodi and Sepolia, read through eth_rpc_module, and says "Your
balances on the chains you have set up". Gone under the platform: the local test Safe card,
the direct propose composer, the mock shielded chain and its seeded MOCK/MTK, and the fake
LEZ chain's funded 1 LEZ (real lez_core by default is exo-d4d.10).

Found on the way: a `##` comment (Nim's) in a QML file left the whole view uncompiled in
Basecamp ("Expected token `;'"), and nix build said nothing. Every QML change gets a launch.

## R6 on display: two fresh installs, Sepolia, a split and a Safe (2026-10-07)

The epic's exit test (exo-d4d.7). Two Basecamp 0.3.1 profiles on Xvfb
(`scripts/basecamp-profile.sh r6-alice --fresh --xvfb :91`, `r6-bob --xvfb :92`), no
`MUSTER_*` variable, the `logos.dev` fleet, each person's own keystore_module account:
Alice's created through the hand-off and never funded (a creditor only agrees and reads),
Bob's funded with Sepolia ETH by a person. Both select their account for approvals and
approve the F-14 link in the Signer.

**A split.** Alice starts "Split a bill" with Bob's chat id; Bob's Home shows the
invitation and he joins (members = 2, re-keyed to epoch 1). Alice proposes 0.002 ETH with
herself in it: `evm-split@eip155:11155111` (the composer names no chain; Sepolia is the
first test chain, `PreferTestnets`), paid to her keystore account. Bob agrees with his
room key, no prompt, then **Pay my share**: the escort raises `evm.signing.approve`, and
the Signer shows "Requested by: tx_sender_module · Pay my share of 'R6 Sepolia dinner',
agreed in a Muster room [asked by muster_module]", one transaction on chain 11155111 to
Alice's account, 0.001 ETH, no data. One approval. **Final on both**, "Settled — every
share confirmed by who it was owed to"; Alice's account holds exactly 1000000000000000 wei
(tx `0x75c88dba…cb8a4`, block 11863612).

**A Safe the members already own.** A 2-of-2 Safe v1.4.1 (Alice, Bob) made outside
muster, with Bob's account through Safe's own `SafeProxyFactory` on Sepolia
(`0x21b6E7328D4B2CBaeC21d2504Dc41FDFffcb86EF`), funded with 0.002 ETH. Alice discloses it
in the room: "evm.safe · eip155:11155111 · the chain agrees: 2 of 2". She proposes
0.001 ETH from it to Bob; each owner approves in their Signer (the SafeTx shown as EIP-712
for that Safe on chain 11155111, plus muster's attestation digest); 2 of 2 → ready. Bob
settles (Alice's account has no gas): one Signer approval of `execTransaction` through
tx_sender_module; **final on both**, the Safe at exactly 0.001 ETH (tx `0xd85b31b4…b34a`,
`ExecutionSuccess`).

A plain transfer to Alice's new account used 204,600 gas, not 21,000: creating an account
costs more on Sepolia now. tx_sender's estimate covered it; nothing for muster to do.

**Found, and fixed in the same branch:**

- **A first registry read before eth_rpc_module answers held muster on the URL path for
  5 min** (exo-9c8). Bob's Settings showed `RPC endpoint · now: http://127.0.0.1:8545`, and
  switched by itself exactly five minutes after launch. Now a miss is read again after
  2, 4, 8 … s (`registryRecheckS`); after the fix Bob switched ~40 s after muster loaded.
- **The same race in the view:** `describe()` is read once at start, so Alice's room still
  offered "Disclose the local test Safe" (Bob's did not: he had opened Account, which
  re-reads it). The view re-reads it on entering a room; the Safe form starts on
  `describe().defaultChainId` (the split chain under the platform), not 31337.
- **The composer said "⚠ not a Safe owner"** to an owner: `coordinate_account` named the
  module's own key while contribute routed the approval to the selected keystore account.
  One rule now decides both (`keystore_approval.safeApprover`).
- **Approve on a Safe card raised no Signer.** The escort followed only `waiting`
  requests; once the Signer has been opened it keeps running and renders a new request at
  once (`shown`) while the person is still in Muster. The escort now follows both.

**Seen, not yet fixed:** the Account view labels chains `evm:11155111` rather than by name;
a Safe card shows the amount in wei; a split card says "Sent 0.001 ETH… (txs:snd_…)"
before the person has approved anything; the composer reads "1 people can read this"; the
`execTransaction` purpose says only "Settle an intent"; the Bitcoin multisig form starts on
regtest; tx_sender's history still says `pending` for both mined transactions (its own
poll, not muster's); a long delivery config overflows Settings.
