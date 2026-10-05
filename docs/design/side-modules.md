# Side-modules: what leaves muster_module, and what never does (epic exo-ff5)

**Status:** proposal, 2026-10-02. The survey behind it read the code at `e75ec71` (after #213, the keystore_module backend). Line references re-pointed to `ba53951` on 2026-10-05, after exo-dbd, exo-ecbe and exo-273 landed or were filed. Plan: epic `exo-ff5`, slices S1–S8 (§7).
**Reads with:** [basecamp-capability-alignment.md](basecamp-capability-alignment.md) (core-to-core calls versus app-to-app intents), [keystore-module-backend.md](keystore-module-backend.md) (exo-149: the first key holder outside muster), [driver-derivation.md](driver-derivation.md) (muster calling other modules), [lez-wallet-delegation.md](lez-wallet-delegation.md). Platform side: the Logos Module Atlas at Basecamp 0.3.1: `stacks/key-custody.md`, `stacks/evm-wallet.md`, `guides/calling-official-modules.md` (github.com/corpetty/logos-module-atlas).
**Paths:** short paths are under `module/src/`. `muster_module.nim` and `muster_gen.nim` are in `module/nim-lib/`. QML files are in `ui/src/qml/`.

## 1. The question

Muster does the hard part by keeping the room's log and folding it. Today it also does everything else in the same process: it holds keys, encrypts the room, signs, reads four kinds of chain, broadcasts, watches for finality, confirms payments, and serves 88 methods to a UI that polls them. Which of that could live in other logos modules, and which must not?

The short answer:

- **Outside IO can leave.** Chain reads, broadcasting and watching touch no key and no room plaintext.
- **Keys can leave, but only to a platform key holder** (keystore_module, lez_core), never to a muster-made module.
- **The room kernel stays.** That means the epoch crypto, the log, authentication, the folds, the drivers, the invariant gates and assembly.
- **Most of the weight the UI feels is not misplaced work. It is work done too often.** Four structural fixes (§3) come before any split and are worth more than the split.

## 2. The process, by what each step touches

Per room, one pipeline:

1. **Identity.** A secp256k1 authorization key and an Ed25519/X25519 encryption key, joined by a signed binding (F-14). Both sit behind the `Keystore` seam (`crypto/keystore.nim`).
2. **Room.** A delivery content topic plus epoch crypto (`crypto/epoch_crypto.nim` behind `ConversationCrypto`). A join request → admit handshake re-keys forward on every admit (F-16).
3. **Log.** `Event = {parents, key, value}`, content-addressed and hash-linked (`log/log.nim:29-48`), sealed under the current epoch key. It lives in memory and is rebuilt from the store node on restart (`transport/store_catchup.nim`).
4. **Authenticate.** `roomEvents` drops any event whose author signature fails (`coordination/authorship.nim:178-196`). Every fold reads it; only `buildProof` reads the raw log.
5. **Fold.** `reduceIntents` → `reduceIntentViews` → home, covers, settle-up, activity, provenance and flow, plus messages, accounts and ceremonies. About 30 folds; most are pure functions of the event set (`coordination/*`).
6. **Act.** Propose, contribute, decline, disclose, share. Each passes the gates: invariant 1 re-derivation (`live.nim` `planApproval`), invariant 2 context and invariant 10 provenance (`attest.nim` `intentInputs` / `allAccountable`). Then it is signed and published.
7. **Settle.** `Settlement.assemble` re-derives and refuses on a mismatch, then submit, then watch (`settlement/settlement.nim`). Payment in parts (`coordination/parts_*`), on-chain votes (`vote.nim`) and FROST aggregation sit here, driven by four pumps.

Grouped by what each part touches:

| Zone | What lives there | Leaves the process? |
|---|---|---|
| **Keys** | `Keystore`: `identity.mks` (secp + the encryption seed), derived LEZ member keys, FROST host keys. FROST round state and nonces are in memory (`frost/keystore_ops.nim`). keystore_module already signs Safe approvals by key ref (#213). | Only to a platform key holder (exo-149) |
| **Room kernel** | epoch crypto, session, log, `roomEvents`, every fold, the drivers' `canonicalize` / `verifyContribution` / `describeFor` / `partTransfer` / `checkRead`, the sign-time gates, `Settlement.assemble`, `frostPump` (no IO), `keystorePump` (the key path) | **Never** (§4) |
| **Outside IO** | `Transport` → delivery_module, the EVM, Bitcoin and LEZ adapters, `safe_rpc`, `LezMultisigLive`, `Settlement.submit` / `watch`, the `PartSeam` implementations, `VoteSeam` casts, `lp_invoker`, readiness probes; the IO halves of `splitPump` and `lezPump` | **Yes** (§5) |

```
                 muster_ui (QML + C++): polls ~7.7 calls/s, whole state
                               │  88 request/response methods, no events
┌──────────────────────────── muster_module ────────────────────────────┐
│  Keys              Room kernel                     Outside IO         │
│  keystore seam     epoch crypto · log              chain reads/watch  │
│  secp + Ed25519    authenticate · fold             broadcast · pay    │
│  FROST nonces      drivers · gates · assemble      splitPump/lezPump  │
└────┬───────────────────┬───────────────────────────────┬──────────┬───┘
     ▼                   ▼                               ▼          ▼
 keystore_module    delivery_module                   lez_core   chain watcher
 (EVM keys, #213)   (sealed bytes only)            (LEZ wallet)  (proposed, S8)
```

## 3. The interfaces as they are

| Interface | Between | Shape | Health |
|---|---|---|---|
| `Driver` | kernel ↔ per-family logic | pure; values in, values out; checked by conformance | **ready**: already clean |
| `Keystore` | kernel ↔ keys | operations only, never a key getter; async via keystore_module | **good** |
| `Transport` | kernel ↔ delivery_module | sealed bytes; already out of process | **good**, apart from the per-session node (§10) |
| `ChainAdapter`, `PartSeam`, `Settlement`, `VoteSeam` | kernel ↔ chains | serializable values, but each takes a `Keystore` ref, and signing and broadcasting happen in one call | **mixed** (S6) |
| `driverFor` | folds ↔ room context | reads `gSession` behind the fold's back (`muster_module.nim:192-201`, `:655-660`) | **impure** (S1) |
| `muster.lidl` | module ↔ UI | pull-only, whole state every call, implicit active room, no events | **poor** (S1–S3) |
| `muster_ui.rep` | backend ↔ QML | 74 slots, 53 JSON-string properties, 0 signals | **poor** (S3) |

Four structural problems sit under the last rows. Each one blocks an offload.

**1. The module has no clock.** Dispatch is synchronous on the host's module thread, and muster runs no loop, timer or thread of its own. Every pump runs inside `coordinate_intents`, and only for the active room (`muster_module.nim:2146-2150`: `gSession.poll`, `lezPump`, `frostPump`, `splitPump`, `keystorePump`). So the UI's one-second Room timer is the module's heartbeat.
- A split payment in a room that is not open is neither reported nor confirmed (`splitPump` reads `gSession` only). This symptom was filed independently as exo-273, now `exo-ff5.9` in this epic. The rooms exo-ecbe now re-enters at startup inherit it, because none of them is made active.
- Headless `logoscore` advances nothing.
- Reads have side effects: `gSession.poll()` fires store queries.

**2. One implicit room.** Room methods take no topic. They act on `gSession` / `gTopic` (`muster_module.nim:633-635`), which `coordinate_join` sets. `driverFor` resolves account-bound policies against `roomAccounts()`, which is `reduceAccounts(gSession.roomEvents())`. Room-kind drivers (threshold, unanimous, frost, invoke) take their roster from `gSession.members()`, which comes from the crypto layer's grants rather than the log. To make `driverFor` resolve correctly, `coordinate_conversations` swaps `gSession` for each room (`:3598-3603`).

**3. Pull-only whole state, recomputed on every call.**
- **Call rate.** With a room open, the UI makes about 7.7 module calls a second:
  - the 1 s Room tick is six calls, because `loadIntents` chains `frost_ceremonies` and `coordinate_activity` (`ui/src/muster_ui_backend.cpp:418-428`);
  - plus the 2 s Home timers and the 5 s and 10 s Room timers.
- **No reuse.** Each call re-reduces the entire log, and no fold is cached.
- **The quadratic sort.** `canonicalOrder` is roughly quadratic (`log/log.nim:50-86`). It runs several times per intent per call: in `reduceIntents`, `intentRecord`, `intentInputs`, `intentContext`, and again inside `approvalGrades`.
- **Repeated account folds.** Every `driverOf` call redoes `roomEvents` and `reduceAccounts`.
- **Push is unused.** The platform supports it (the SDK's `emit`; `muster_gen.nim` installs the callback), but `muster.lidl` declares no events.

**4. Domain rules in QML.** Rules that decide what gets proposed or agreed exist only in the UI, so every UI must copy them, the seaqt port (exo-607.8) included:
- `Room.qml:621-637` builds the Safe effect.
  - **Value:** the value goes through `parseInt`, which is exact only to 2^53 wei.
  - **Nonce:** the nonce falls back to 0 when it is unknown.
- **Split arithmetic:** `Room.qml:776-880` copies the split arithmetic from `drivers/split.nim`.
- **Propose gate:** `Room.qml:405-412` holds the propose gate.
- **Admission:** `Room.qml:574` and `:596` decide auto-admit and re-ask.
- **Room topics:** `Composer.qml:127-134` mints room topics with `Math.random`.

## 4. The rule for what may leave

**Invariants that pin the kernel in place:**
- **1:** the re-derivation lives in the module core and cannot be disabled.
- **7:** the epoch boundary.
- **9:** the boundary is the room.
- **10:** the refusal of an unaccountable input happens at sign time, next to the key.

**Platform facts that close the remaining options:**
- **The event plane carries no auth token.** A payload reaches every subscriber, so it can carry ids and heads, never plaintext (atlas `guides/calling-official-modules.md` §4; keystore_module's events carry the handle only, for the same reason).
- **A Nim provider cannot see its caller.** `logos_module_set_call_caller` is not exported to Nim, so there is no `current_caller()` (same guide, §3).
- **Basecamp runs with the access policy off by default.** Any loaded module can call any other (`stacks/key-custody.md`).

Put together, a side-module that holds decrypted room data would serve it to every co-resident module. That is already true of `muster_module` itself: `coordinate_messages` answers anyone, for the same reasons (§9). Splitting the kernel would not add a new kind of exposure. It would add another copy of the plaintext, in another process, with nothing gained.

**The rule:**
- **Move out what touches the outside world**, provided the kernel signs everything before handing it over, and receives raw values with their source.
- **Move keys only to a platform key holder.**
- **Keep everything that touches room plaintext.**

## 5. Verdicts

| Candidate | Verdict | Why |
|---|---|---|
| Chain watching and broadcast (Bitcoin, LEZ multisig inclusion, Safe execution finality, part confirmation) | **Yes: a new key-less module (S8)** | No key, no plaintext beyond what goes public on chain anyway. Takes blocking IO off the dispatch thread and gives progress a clock that does not depend on the UI. |
| EVM reads and sends | **Yes: adopt the official modules (S7)** | `eth_rpc_module` (with `verified_proxy_module`), `fee_module` and `tx_sender_module` already exist, with one nonce ledger per device. Safe settlement moves under exo-149.4. Basecamp only: the standalone runner keeps the in-process path. |
| EVM key | **Already moving** | keystore_module, exo-149 (#213). |
| LEZ wallet, proofs, scans | **Already out** | lez_core, over `lp_*` with a 900 s async budget for proofs. |
| Transport | **Already out** | delivery_module. |
| Room crypto (`ConversationCrypto`) | **Later, to chat_module** | A platform module, as ADR-010 intends, but not yet: in 0.3.0 an account is new on every `init` (exo-eb6.5). |
| Folds and read models | **No** | They need decrypted, authenticated events (§4). The driver-dependent folds need byte-identical driver code, so version skew between two modules would show a state the kernel would not sign. The kernel computes the gate folds anyway. Make them cheap in place (S4) and push changes (S3). |
| Drivers | **No** | They are on the signing path (invariants 1 and 6). ADR-007 and P5 isolate *plugins* that emit blocks, not drivers. Tier-0 `invoke` already makes other modules' actions coordinatable without new drivers. |
| Bitcoin and FROST primitives | **A shared Nim library, not a module** | Sighash, scripts, the PSBT canonical form and FROST math are re-derivation code (invariant 1). They could be extracted the way logos-nim-sdk was, but they stay linked into the kernel. |
| The audit / proof verifier | **Not now** | `module/tools/muster_audit_verify.nim` already verifies from the file alone. A module is worth it only when another app needs to verify. |

## 6. The chain watcher, sketched

A logos core module that holds no key and sees no room plaintext:

```
module muster_chain_watcher {
  version "0.1.0"
  depends []
  method watch(request_json: tstr) -> tstr description "Watch for one fact: {ref, chain (CAIP-2), kind: tx | output | inclusion | nonce, target, endpoint}. The endpoint comes from muster's settings (invariant 8); the watcher originates nothing of its own."
  method unwatch(ref: tstr) -> tstr
  method broadcast(chain: tstr, raw_hex: tstr, endpoint: tstr) -> tstr description "Send bytes the kernel already signed. Returns {ref}."
  method observations(since: uint) -> tstr description "The values: [{ref, seq, value, source, height}]. The poll backstop and the only way values leave."
  event observed(ref: tstr, seq: uint) description "Ids only: the event plane carries no token."
}
```

**How each invariant holds:**
- **Invariant 1.** The kernel does every comparison. It holds the derived `PartTransfer`, the re-read pointer (`checkRead`) and the expected output; the watcher only reports what the chain says.
- **Invariant 10.** Every observation that reaches a signed payload is recorded by the kernel as an `intent/<id>/read/<field>` event with its source.
- **Invariant 8.** The endpoint for every call comes from muster's settings and is visible there.
- **Invariant 4.** The watcher's only state is its watch list, which the kernel re-sends on restart. The log and the pending book (`split-pending.json`) stay the truth.

**What moves into it:**
- the IO halves of `splitPump`: Bitcoin and EVM part landed/gone checks, and the creditor's confirmation reads;
- `lezPump`'s inclusion polling;
- the ~4 s finality wait inside `coordinate_submit` (`muster_module.nim:3017-3023`);
- `BitcoindAdapter` reads and broadcast.

**What stays in the kernel:** `frostPump` (no IO), `keystorePump`, `Settlement.assemble`, `checkRead`, and every read record.

**Privacy note.** The watch list is room-derived metadata: which addresses and transactions this device cares about. The RPC endpoint sees it anyway (invariant 8), but so would any co-resident module that calls `observations`. That is why the event carries ids only. It is a reason to keep the watch list scoped and short-lived, not a reason to keep the IO in-process.

## 7. The plan

| Slice | What | Depends on |
|---|---|---|
| `exo-ff5.1` S1 | Room context explicit: a `RoomCtx {session, accounts, roster}`; `DriverFor(kind, ctx)`; topic-scoped room methods | — |
| `exo-ff5.2` S2 | Kernel clock: `coordinate_tick` advances every joined room; reads become side-effect free. Fixes `exo-ff5.9` structurally; that interim can land first, and S2 replaces its swap with `RoomCtx` | S1 |
| `exo-ff5.3` S3 | Plaintext-free events (`room_changed(topic, head)`, `intent_changed`, …), emitted from the tick on the module thread; the UI subscribes and keeps a slow poll | S2 |
| `exo-ff5.4` S4 | Fold cache keyed by (log heads, roster epoch, accounts); `canonicalOrder` in O(N log N) with cached ids | S1 |
| `exo-ff5.5` S5 | Domain rules out of QML: effect builders from typed parameters, split preview, propose gate, admission, CSPRNG topics | — |
| `exo-ff5.6` S6 | Signing separate from broadcasting at the chain seams; reads return `{value, source, height}` | — |
| `exo-ff5.7` S7 | EVM reads via `eth_rpc_module`, part payments and `wallet_send` via `tx_sender_module`, fees via `fee_module` | S6, exo-149.4 |
| `exo-ff5.8` S8 | The key-less chain watcher (§6) | S2, S6 |
| `exo-ff5.9` (filed as exo-273) | The interim for the symptom: every joined room pumps, whichever is open — each session's pumps run with that room swapped into `gSession`, as `coordinate_conversations` already does | — |

S1, S5, S6 and the `exo-ff5.9` interim can start in parallel. **S1–S4 are worth doing even if nothing ever leaves the process:**
- they give headless runs and closed rooms a clock;
- they cut the per-second cost by an order of magnitude;
- they give the seaqt port (exo-607) a contract it can bind without copying logic.

Once S1–S2 land, the kernel/effector boundary should become an ADR (the next free number is ADR-016) in `docs/02-implementation-plan.md`.

## 8. Costs and risks

- **IPC per call.** Each hop is a QtRO round trip. The watcher's interface is coarse (watch once, observe many), which keeps that small.
- **The out-of-process token handshake.** Under `logoscore`, modules outside the standalone runner's process have hit capability-token failures (`docs/labbook/logoscore-out-of-process-module-auth.md`). Every new module inherits this. Prove S8 headless before building on it.
- **Bundling.** The standalone runner and the AppImage must ship each new module (as with delivery_module, `make build`).
- **Basecamp-only paths.** S7 works only where keystore_module can attest muster. Until the standalone runner can, both paths live side by side, and the readiness grade must say which one is active.
- **New state outside "log + keys".** Anything a side-module keeps must be advisory, or re-sendable from the kernel.

## 9. Open questions

1. **A clock for a Nim core module.** S2 makes the tick explicit, but someone still has to call it (the UI timer or a headless script). Can a Nim module own a timer that safely schedules work on its own module thread? Options: a self `lp_invoke_async`; a thread that only enqueues, drained like `InboundQueue`. Rust modules spawn threads; muster has no precedent.
2. **Caller identity for muster's own surface.** Any co-resident module can call `coordinate_messages` today. Closing that is upstream work: export `logos_module_set_call_caller` to Nim (logos-nim-sdk), then gate by caller, and run with the access policy on (`infra/access-policy.json`). Whatever the answer, it applies to the kernel, not just to side-modules.
3. **Does the watcher generalize?** No official Bitcoin module exists in Basecamp 0.3.1 (atlas `gaps.md`). A key-less Bitcoin node client could serve other apps; muster's needs (scantxoutset, gettxout, sendrawtransaction, confirmations, mempool spends) are a reasonable first contract.
4. **In-flight LEZ steps.** `gLezPending` is in memory only (`muster_module.nim:982`), so a vote or Execute already sent is forgotten on restart. Decide whether S8 persists the watch list or the kernel persists its pending steps the way `split-pending.json` does. The kernel is the likelier owner.

## 10. Found along the way

Not part of the plan; recorded here so they are not lost. Each was confirmed by reading the code, not by a test.

- **Intent ids were not re-derived in folds. Fixed in exo-dbd (`bc90342`).** A member could publish a second `intent/<id>/propose` (or `/policy`) under an existing id, and approval signing and the fold picked different copies. Now `proposalOf` (`intent_events.nim`) counts a propose/policy only as the pair the id is the hash of. The same gap for `intent/<id>/context`, which the id hash does not cover, is filed as exo-f12.
- **Epoch-0 history after a restart.** `coordinate_join` always founds a fresh epoch-0 key (`muster_module.nim:741`, `epoch_crypto.nim:84`). A founder appears unable to read anything posted before the first admit after a relaunch, which would break "rebuilt from log + keys".
- **Untimed RPC on the dispatch thread.**
  - `safe_rpc.nim:56-62` uses `newHttpClient()` with no timeout;
  - `evm_rpc.nim` and `lez_multisig_live.nim` run `waitFor` with none set;
  - `safeNonce` reads a null result as 0.
- **The flow view never subtracts admitted members from its founders.** `musterCoordinateFlow` compares a `0x`-prefixed hex string to the bare hex in admit keys (`muster_module.nim:2547-2549`).
- **One delivery node per session.**
  - `newDeliveryTransport` runs `createNode` + `start` for every room and every inbox (`muster_module.nim:741`, `:789`), contrary to the comment at `:782`.
  - Inbox sessions made for invites are never polled again.
  - Whether delivery dedupes repeated `createNode` calls is upstream behaviour to check.
- **The invariant-3 comments contradict `LezMultisigLive`.**
  - What the comments say: three of them say muster never signs LEZ multisig transactions (`lez/multisig_chain.nim:7`, `drivers/lez_multisig.nim:6`, `coordination/vote.nim:4`).
  - What the code does: `LezMultisigLive` signs them with `lezMemberSign`.
  - Why: the stopgap is documented in exo-a50.7. Invariant 3 concerns plugins, so the comments misstate it.
