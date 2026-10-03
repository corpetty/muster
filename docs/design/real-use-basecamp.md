# Real use on Basecamp: the platform's keys and chains, nothing seeded (epic exo-d4d)

**Status:** proposal, 2026-10-03. Epic `exo-d4d`, slices `exo-d4d.1`–`.8` (§7; `pb dep tree exo-d4d`). Builds on [side-modules.md](side-modules.md) (exo-ff5, which
decides what may leave `muster_module`) and [keystore-module-backend.md](keystore-module-backend.md)
(exo-149, whose K1, K2 and K5 have landed).
**Reads with:** the Logos Module Atlas at Basecamp 0.3.1, `stacks/evm-wallet.md` §6 ("Using this
stack from a third-party module") and `guides/compatibility.md` (github.com/corpetty/logos-module-atlas,
read at `82593d5`).
**Paths:** short paths are under `module/src/`; `MM` is `module/nim-lib/muster_module.nim`.

## 1. The goal

A person installs Basecamp, installs Muster from a package, and uses it with keys and chains
they already have. Nobody seeds a key, points it at anvil, or sets an environment variable.

Today every multi-party run needs seeding: `scripts/try-peer.sh` and `scripts/demo-peer.sh`
set `MUSTER_DEV_SECP_KEY` to an anvil owner key and `MUSTER_RPC` to a local anvil, and the
module defaults to `http://127.0.0.1:8545` and chain 31337. That was right for proving the
invariants. It is wrong for anyone else.

**Basecamp is the default host from here on.** The standalone runner stays as a test
harness, not the product. Basecamp 0.3.1's catalog already ships the pieces a person needs:

| Need | Platform module | Muster today |
|---|---|---|
| An EVM key, created, backed up, imported | `keystore_module` (custodian UI: `evm_keystore_ui`) | `FileKeystore`'s secp key, minted or seeded |
| A human approving each signature | `evm_signer_ui` via `evm.signing.approve` | nothing; signs silently |
| Which chains, which endpoints, Tor, verified reads | `eth_rpc_module` (+ `verified_proxy_module`, `eth_rpc_ui`) | one global `gRpcUrl` for every chain |
| Fees | `fee_module` | `eth_gasPrice`, fixed gas limits |
| Sending, with one nonce ledger per device | `tx_sender_module` | signs and broadcasts itself, or `eth_sendTransaction` on an unlocked anvil account |

## 2. What changes, and what never does

Moving to the platform changes **where keys and chain IO live**. It does not change what
muster checks (side-modules §4):

- **Invariant 1.** Every signature that comes back from `keystore_module` must recover to the
  chosen account **over muster's own hash** (already so in `wallet/keystore_requests.nim`).
  A send through `tx_sender_module` is built from the agreed effect; muster compares what the
  sender prepared (`to`, `value`, `data`) with what it derived, and refuses a mismatch before
  asking for approval.
- **Invariant 10.** A chain read that reaches a signed payload is recorded with its source.
  `eth_rpc_module` answers every read with a `route` (`verified` | `proxied` | `direct`); that
  becomes the read record's source, and the F-10 badge (`verified` vs `attested`) is the
  route, not a guess.
- **Invariant 8.** Endpoints stay the user's. They are now set once, device-wide, in
  `eth_rpc_ui`, not per app. Muster reads them; it never overwrites them (no
  `set_chain_config`, only `init_defaults`, which seeds nothing that exists).
- **Invariant 3 and the key rule.** Muster never holds an EVM key under Basecamp, never
  creates one (Tier D is the custodian's), and never approves one (Tier A is the signer's).

The room's Ed25519/X25519 encryption identity stays in muster's keystore. No platform module
holds it, and it is already persistent.

## 3. Where muster's EVM code stands (mapped 2026-10-03)

**Reads.** Two transports, both keyed by a URL, both synchronous with no budget on `main`
(`wallet/rpc_budget.nim`, exo-14f, is on an unmerged branch):

- `wallet/evm_rpc.nim` (nim-web3): balance, call, gas price, chain id, nonce (pending and
  latest), send raw, receipt status, transfer-of, receipt logs, `eth_sendTransaction`,
  `eth_getProof`.
- `drivers/safe_rpc.nim` (std/httpclient): Safe nonce, owners, threshold, modules, guard,
  balance, `execTransaction` via `eth_sendTransaction`, receipt watch, `probeRpc`.

Every caller uses the one global `gRpcUrl`: `EvmAdapter` (the wallet, hard-coded to
`evm:31337` at MM:3622), `EvmPartSeam` (split payment and confirmation), `settlementFor`
(Safe settle), `chainViewOf` / `bypassesOf` (the accounts view), readiness, connectivity,
`tokenInfo`. A chain other than the one at `gRpcUrl` is refused by an `eth_chainId` check,
so **a room cannot use two EVM chains at once today.**

**Signing.** Through `FileKeystore`'s secp key:
- split part payments, ETH and ERC-20 (`signLegacyTransfer`, legacy EIP-155);
- Safe `execTransaction` with relayer `self`;
- Safe approvals and EIP-191 statements (`liveContribute`): the contribution, the
  attestation, the F-14 binding.

`wallet_send` on EVM signs **nothing**: it calls `eth_sendTransaction` on an unlocked anvil
account. Only Safe approvals can already route to `keystore_module`, behind
`keystore-backend = interim`.

**Approvals in the UI.** `muster_ui` never raises `evm.signing.approve`; `ui/metadata.json`
has `"uses": []`. An approval waits until the person opens the signer by hand, or an
`evm_signer_cli` operator approves headless.

**Seeding.** `MUSTER_DEV_SECP_KEY`, `MUSTER_RPC`, `MUSTER_KEY_PASSPHRASE` (default
`muster-dev-passphrase`), the anvil owners and Safe (`OWNER0..2`, `SAFE_ADDR`, `gDevSafe`)
offered by `describe()`, and the `environment: eip155:31337` setting.

## 4. The host comes first

Muster has never been installed into a Basecamp 0.3.1 release. Every `keystore_module` run so
far is headless `logoscore` 0.3.1. The atlas's compatibility guide names what has to line up:

| # | What | State |
|---|---|---|
| H1 | **`muster_module` loads.** The Nim backend defines the protocol-0.2 module ABI (7 exports). The host admits any `0.x` (rule 1), and `logoscore` 0.3.1 already loads it. | Expected to work; never tried in Basecamp |
| H2 | **`muster_ui` renders.** A `ui_qml` plugin must share the host's SDK generation (rule 4). The UI pins builder `4717b9af` (2026-07-22); the 0.3.1 generation is builder `0.3.1` (`16e2f6bd`). | **Likely blank** (`std::bad_alloc` or "Timeout waiting for ui-host"). exo-eb6.6 |
| H3 | **Packages install.** Dev `.lgx` → a nix-built Basecamp; `.#lgx-portable` → the release AppImage. Local installs do not resolve dependencies, so the catalog modules go in first. | Untested |
| H4 | **Attribution.** `keystore_module.caller_identity()` from muster answers `{kind: module, identity: muster_module}` with an approver set. | Verified under `logoscore` 0.3.1 (exo-149.1); not in Basecamp |
| H5 | **Current module ABI.** Five exports missing from `logos-nim-sdk` (`grant_host_services`, the unload pair, `set_call_caller`, `accept_inbound_token`) plus a real `get_protocol_version`, then the builder #226 commits rebased on `0.3.1`. | Not needed to load (H1); needed to leave the forked builder and to read callers |

H1–H4 are the first slice. H5 is real but not on the critical path.

## 5. The design

### 5.1 Keys: the member's EVM account is a keystore_module account

- **Which account.** Muster lists `keystore_module.list_accounts()` (Tier C, ungated) and the
  person picks one (K5's `keystore_select`, already built). That account is the member's
  EVM identity in every room. Its F-14 binding is signed once at selection (K5).
- **No account yet.** Readiness reports the authority requirement as missing, with the remedy
  "Create or import an account" → `logos.request("evm.accounts.manage")` (the custodian UI).
  Muster never creates or imports keys.
- **Under Basecamp, `keystore-backend` defaults to the platform.** `FileKeystore`'s secp key
  stays for the runner and tests. The rename: `off` → `file`, `interim` → `platform`, with the
  interim digest leg (keystore-module-backend.md §4) still flagged on the card until K6.
- **Every EVM signature goes through a human.** That is the platform's rule and the right
  one for real money. It changes the feel: approving a Safe intent, paying a split share and
  settling a Safe each open the signer once.

### 5.2 Approvals: the UI raises the signer (exo-149.3, K3)

- `ui/metadata.json` gains `"uses": [{"intent":"evm.signing.approve"},
  {"intent":"evm.accounts.manage"}]` (objects: a bare string array is silently ignored).
- When a module call answers `{pending: true, handle}`, `muster_ui` calls
  `logos.request("evm.signing.approve", {handle}, cb)`. The callback is advisory; the card's
  state comes from the module's status poll (`keystore_requests`, `tx_sender.send_status`).
- `unavailable` (no signer installed) does not cancel: the card says "Open the Signer", and the
  person can.

### 5.3 Chains: `eth_rpc_module` behind the `evm_rpc` seam

- **One seam, two backends.** `evm_rpc.nim`'s procs take an endpoint value, not a URL string:
  `EvmEndpoint = {direct url} | {platform chainId}`. The direct backend is today's nim-web3
  code (the runner, anvil e2e tests). The platform backend calls `eth_rpc_module` over
  `lp_*`: `get_balance`, `call`, `get_transaction_count`, `get_transaction_receipt`,
  `get_transaction_by_hash`, `block_number`, and `raw_rpc` for `eth_getProof`,
  `eth_getStorageAt`, `eth_getLogs`.
- **`safe_rpc.nim` joins the seam.** Its own std/httpclient transport goes, so there is one
  EVM transport, not two.
- **The chain comes from the account, not a global.** A CAIP-2 `eip155:<id>` selects the
  endpoint per call. A room can hold a Safe on Sepolia and a split on mainnet at once. The
  `rpc` setting stays only for the direct backend.
- **Which chains exist** is `eth_rpc_module.list_chain_configs()` filtered by its network
  scope. The composer offers those, named by `chainLabel` (exo-e71). Muster calls
  `init_defaults()` at start (idempotent; the platform's own rule) and nothing else that
  writes.
- **Reads carry their route.** Each read returns `{value, route, height?}` (side-modules S6).
  `route = verified` is the green badge; `verified_blocked` is a raise, never a zero (the
  wallet's failure rule).
- **Budgets.** `eth_rpc_module.call` takes a `deadline_ms`; every platform read passes one.
  Calls stay synchronous on the module thread for now, as they are today; the async watcher
  is side-modules S8.

### 5.4 Sends: everything through `tx_sender_module` (exo-149.4, K4)

Every transaction muster originates goes `prepare → send → evm.signing.approve →
send_status`. Muster never signs a `tx` leg and broadcasts it itself (that bypasses the
device's one nonce ledger).

| Flow | Calls |
|---|---|
| Split part, ETH | `[{to: payTo, value: share}]` |
| Split part, ERC-20 | `[{to: token, data: transfer(payTo, share)}]` |
| Settle-up net transfer | the same, one per net payment of mine |
| Safe settle | `[{to: safe, data: execTransaction(…, signatures)}]` |
| `wallet_send` | `[{to, value}]` or the ERC-20 form |

- **Checked before approval.** `prepare` answers the legs it will send. Muster compares each
  leg's `to`, `value` and `data` with the transfer it derived from the agreed effect
  (invariant 1) and refuses a mismatch before calling `send`.
- **A pending table** keyed by `requestId`, the same shape as `SignRequests`, persisted the way
  `split-pending.json` is (exo-a90.23), because a part in flight must never be forgotten.
  `send_status` is polled until `final`; `broadcast` gives the hash the part report names.
- **`purpose`** is what the room agreed ("Pay my share of 'dinner' to Devon"); `meta` carries
  the intent and part ids so the wallet's history joins back.
- **Shared cap.** `tx_sender_module` holds 4 live approvals for every app on the device. A
  refusal at the cap is a visible state on the card, not a failure.
- **Gone.** Relayer `unlocked:` and `eth_sendTransaction` stay for anvil tests only.

### 5.5 Typed attestation (exo-149.6, K6)

On the platform path every Safe approval shows the human an opaque 32-byte digest beside the
SafeTx. The interim is acceptable on testnets and must not reach mainnet. K6 (an ADR, then
verifiers that accept an EIP-712 form) is the gate for mainnet, not for this epic's testnet
milestone.

### 5.6 A clock for every room (exo-273, side-modules S2)

An approval in the signer can take minutes, and the person may be on Home or in another room
when it lands. Today `keystorePump` publishes into whichever room is **active**, and
`splitPump` runs only for the active room. Both must run for every joined room, each request
publishing into the room it came from. This is exo-273, and it is on this epic's path.

### 5.7 Seeding retires to the test harness

- `describe()` stops offering the anvil Safe unless the direct backend is pointed at chain
  31337.
- `MUSTER_DEV_SECP_KEY`, `MUSTER_RPC`, the `AUTO*` hooks and the anvil constants stay, used
  only by scripts and tests, and never read under Basecamp's platform backends.
- A fresh install's first screen says what is missing (an EVM account, a chain in scope) and
  hands off to the app that provides it.

## 6. What stays out of scope

- **Bitcoin.** No platform key holder or node module for Bitcoin exists in the 0.3.1 catalog.
  `btc.split` and the PSBT families keep muster's key and the user's own node.
- **LEZ.** Already on the platform (`lez_core`). Its provisioning is exo-44b.
- **Moving muster's room crypto to `chat_module`.** ADR-010; exo-eb6.5.

## 7. The plan

| Slice | What | Depends on |
|---|---|---|
| `exo-d4d.1` R0 | **Muster in Basecamp 0.3.1.** Re-pin the UI builder to `0.3.1` (exo-eb6.6); install muster's packages next to the catalog's EVM stack in a nix-built Basecamp, then the AppImage; on a display (Xvfb): the view renders, `health` is ok, `keystore_status` reads `module/muster_module` with an approver. A labbook entry for each wall | — |
| `exo-d4d.2` R1 | **The approval round trip in Basecamp.** K3: `uses` objects, `evm.signing.approve` from the card; `keystore-backend` defaults to `platform` under Basecamp; the "no account" remedy via `evm.accounts.manage` | R0 |
| `exo-d4d.3` R2 | **The `evm_rpc` seam with a platform backend.** `EvmEndpoint`; `safe_rpc` onto the seam; reads return `{value, route}`; endpoint per call from the CAIP-2 chain; `eth_rpc_module` in `dependencies` with a version range | — (testable headless under logoscore) |
| `exo-d4d.4` R3 | **Every room advances** (exo-273 / side-modules S1–S2) | — |
| `exo-d4d.5` R4 | **Sends through `tx_sender_module`.** Split parts (ETH, ERC-20), settle-up, `wallet_send`, Safe settle; prepare-then-compare; a persisted pending table | R2, R1 |
| `exo-d4d.6` R5 | **Seeding retires.** `describe()`, defaults, first-run readiness and remedies, docs; the runbook for a fresh install | R1, R2 |
| `exo-d4d.7` R6 | **Acceptance: two fresh Basecamp installs, Sepolia, a split end to end.** Two `--user-dir` instances, each with its own keystore account funded from a faucet; propose → agree → pay through the signer → the creditor's own read confirms → final on both. No `MUSTER_*` variables. Then the same with a Safe the members already own | R0–R5 |
| `exo-149.6` R7 | **Typed attestation** (exo-149.6, K6): the mainnet gate | R1 |
| `exo-d4d.8` R8 | **The current module ABI** (H5): `logos-nim-sdk` exports, builder rebase, muster leaves the forked builder | — |

R2 and R3 can start while R0 is in progress. R6 is the epic's exit test, and it is the first
time two people could use muster without anyone seeding it.

## 8. Open questions

1. **Does the 0.2-generation `muster_module` load beside 0.9-generation catalog modules in
   Basecamp, and call them?** It does under the runner (delivery v0.3.0) and under `logoscore`
   (keystore_module). R0 answers it for Basecamp.
2. **Sepolia or Hoodi for R6?** Both are seeded by `eth_rpc_module.init_defaults()`. Sepolia
   has the Safe v1.4.1 deployments and more faucets, so it is the default.
3. **The approval count.** A split debtor approves twice (agree with the room key: no prompt;
   pay: one signer prompt). A Safe owner approves once per intent plus once per settle. Is a
   prompt per Safe approval acceptable, or does the K6 typed form need to batch the
   attestation into the same EIP-712 document? (It already shares one prompt as two legs.)
4. **Verified reads by default?** `verifiedProxyMode` is device-wide and the user's. Muster
   shows the route; it should not flip the mode. Whether the card should *ask* for verified
   mode before a large settle is a product question.
