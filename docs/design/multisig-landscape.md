# One multisig experience, many multisigs

**Status:** design (epic exo-68f); **Phase A landed** (epic exo-a50: the family profile, one kind list, accounts disclosed by members, Safe fidelity against the real Safe v1.4.1, the settlement seam, the card's fixed rows — exit test `module/tests/phase_a_exit_test.nim`). Phases B–D proposed. Registry: `contracts/families/registry.json` (45 families, checked by `scripts/check-family-registry.py`). Nothing in §5–§6 is built yet. What exists today is the room drivers (`threshold`, `eip191`, `invoke`, the `frost` scaffold), one hard-coded Safe (`gDriver`), and the action manifest (`docs/design/action-manifest.md`). The landscape was verified against primary sources as of 2026-09-23; each registry entry lists its sources, and anything that couldn't be confirmed is listed under `unverified`. **Decisions recorded 2026-09-23** (§9). Interactive atlas: `docs/design/multisig-atlas.html`, a self-contained page (open it from a checkout) with the registry embedded.

## 0. The claim

Every multisig tells the same story:

1. **Set up** a shared account.
2. **Propose** an action.
3. Everyone **reviews** what would be signed.
4. **Collect** enough approvals.
5. **Settle.**
6. **Govern**, which means changing who can sign.

Where multisigs differ is in about a dozen specific ways, and every one of them is a *consequence* a member should see:

- who learns who signed;
- whether a signature can be replayed elsewhere;
- whether approving costs money;
- whether collected signatures expire;
- whether changing signers moves the address;
- whether something can get around the threshold.

Muster's job is to run **one flow with fixed slots**, and to show the differences as **consequence lines in those slots**, each classified by how credible it is (the credibility axis, `action-manifest.md` §2). The flow should never branch into a different product per chain. If a Safe, a Bitcoin vault, a Squads multisig and a FROST key all go through the same five-step card, and the card tells you truthfully how each one differs, then muster is the place to manage any multisig.

Two sentences carry the whole design:

- **A family is `scheme × settlement`, described by a profile. An account is a family made concrete.** So adding a family usually means writing a profile and a canonicalization, not a new driver architecture (§5).
- **The card has fixed slots, and a phrasebook fills them from the profile.** So the experience feels the same because the *questions* are the same. Only the answers change (§6).

## 1. The universal lifecycle

Muster's six claims-registry steps are `open-room · propose · collect · executable · submit · settle`. Two more stages are what make it a *multisig* manager rather than a proposal tool: **setup** (the account comes into being or is imported) and **govern** (the signer set changes). Neither is a new kind of thing. Both are proposals whose effect targets the account itself.

| Stage | Same for every family | Where families differ (the slot that shows it) |
|---|---|---|
| **Setup** | the account is declared in the room log | derive / register / deploy / key ceremony (*Account* slot) |
| **Propose** | an effect is written, with its account and policy | what the effect must pin down: fee (Bitcoin), nonce (Safe), blockhash or durable nonce (Solana), spending path (miniscript) |
| **Review** | muster rebuilds the signable bytes and refuses on mismatch (invariant 1) | same bytes for all, a different blob per signer, or a *pointer* muster must read from the chain first (*What you sign*) |
| **Collect** | approvals fill the slots up to the threshold | one round or two; secret state between rounds; each approval an on-chain transaction; what an approval costs (*Collect* rail sub-steps, *Cost*) |
| **Settle** | one party submits and muster watches finality | executor pays or each voter already paid; how final "final" is (*Settle*) |
| **Govern** | changing signers is a proposal | same address, new address plus sweep, or a new key ceremony (*Account* slot) |

## 2. The dimensions along which multisigs differ

The registry's closed vocabulary (`about.vocabulary`) comes from these dimensions. Each one changes something in muster and has a card slot.

| # | Dimension | Values | What it changes in muster | Card slot |
|---|---|---|---|---|
| 1 | **Locus**: where the threshold is enforced | native · contract · vote · aggregate · room | the shape of collection: in the room (native/contract/aggregate) or on the chain (vote) | *How this account works* |
| 2 | **Scheme**: what a contribution is | same bytes · a blob per signer · own transaction · aggregate partial (n-of-n / t-of-n) | whether there is one materialization or one per signer; whether contributions are chain transactions | *What you sign* |
| 3 | **Commits** | content · pointer | a pointer approval (Squads, TON, NEAR, pallet-multisig) is only safe if muster reads the pointed-at content from the chain and re-derives it *before* you approve | *What you sign* |
| 4 | **Binding**: do the chain-signed bytes name the network? | explicit · implicit · **none** · room | invariant 2 can only hold at the chain layer when binding is explicit or implicit. With `none` (XRPL ids ≤1024, Hedera, LEZ public, Monero, 7702 chain_id 0), muster binds the environment in the room and the chain does not, so the card says so | *Only valid on* |
| 5 | **Ordering** | sequence · lanes · utxo · objects · index · dedup · none | conflicts between concurrent proposals, and "queued behind #N" | *Ordering* |
| 6 | **Expiry** | none · optional · forced (with a window) | a countdown; durable-nonce or scheduled-tx workarounds; "signatures never expire, to cancel …" | *Ordering* |
| 7 | **Rounds, secret state, setup** | rounds; secret nonce state yes/no; derive · register · deploy · dkg | multi-round collection; a keystore operation for one-time secrets; a key ceremony held in the room | *Collect* rail, *Account* |
| 8 | **Signer change** | in-place · new-address · reshare · fixed | whether "govern" is one proposal or a migration of two proposals | *Account* |
| 9 | **What the chain learns** | policy / signers: never · at setup · each vote · at spend; effect: public · shielded · room only | the chain-observer rows in *Who will see what* | *Who will see what* |
| 10 | **Approver cost** | none · per signature · a transaction per vote (+ deposit) | "approving costs you …"; each voter needs gas and their own chain account | *Cost* |
| 11 | **Bypasses** | a list, or none known, or unknown | an honest threshold line: a Safe module, a Squads spending limit, a 7702 root key or a Sui alias can all act without the k signatures | *How this account works* |
| 12 | **Interop** | PSBT, Safe Tx Service JSON, PCZT, SEP-7, … | signers who don't use muster (a Keycard Shell or Coldcard cosigner) take part through the family's own format | *Approvals* (a "signs outside muster" marker) |
| 13 | **Infra** | rpc · utxo source · bundler · mirror node · prover · durable-nonce account | driver-declared requirements; the room shows only what a proposal brings in (exo-428) | *What this needs*, *Connections* |
| 14 | **Maturity** | production · early · draft · experimental · demo · deprecated · sunsetting | a badge on the account, never hidden | *Account* |

Two findings stand out across the landscape. Both were confirmed from primary sources.

- **The approval does not always cover the action.** Squads v4 approvals point at a transaction index. TON multisig v2 approvals point at an order address. NEAR `confirm(request_id)` points at a request id. Substrate intermediate approvals cover a call hash. ZeroDev's `Approve` leaves out gas and paymaster fields. Invariant 1 ("effects are reviewed, materializations are signed, the client re-derives") therefore has a second half for these families: *the thing pointed at is read from the chain and re-derived before the approval is offered*. That read is an **external read** under invariant 10.
- **The chain signature does not always name its chain.** XRP Ledger mainnet, testnet and devnet signatures carry no network id. Hedera bodies carry none. LEZ public messages commit to no zone id. Invariant 2 says a signature must be worthless anywhere else. Muster can make that true of *its* envelope but not of the chain's bytes. Those families carry an `exposure` line, and the checker refuses a planned family with `binding: none` that doesn't name one.

## 3. The landscape

One row per family, generated from the registry (`contracts/families/registry.json` is the source of truth; regenerate rather than hand-editing). ⚿ means secret state is held between rounds (a nonce that must never be reused).

<!-- landscape-table:begin -->
| Family | Locus | Signs | Binding | Rounds · setup | Signer change | Chain learns policy / signers / effect | Ordering · expiry | Approver pays | Maturity | Muster |
|---|---|---|---|---|---|---|---|---|---|---|
| `room.threshold` | room | same bytes | room | 1 · none | in-place | – / – / room only | none · optional | – | production | built |
| `room.eip191-attest` | room | same bytes | room | 1 · none | in-place | – / – / room only | none · optional | – | production | built |
| `room.invoke` | room | same bytes | room | 1 · none | in-place | – / – / the module it calls | none · optional | – | production | built |
| `room.frost-scaffold` | room | same bytes | room | 2 · none | in-place | – / – / room only | none · optional | – | demo | partial |
| `evm.safe` | contract | same bytes | explicit | 1 · deploy | in-place | setup / spend / public | sequence · none | – | production | built |
| `evm.safe-4337` | contract | same bytes | explicit | 1 · deploy | in-place | setup / spend / public | lanes · optional | – | production | candidate |
| `evm.erc7579-ownable` | contract | same bytes | explicit | 1 · deploy | in-place | setup / spend / public | lanes · optional | – | early | candidate |
| `evm.kernel-weighted` | contract | same bytes | explicit | 1 · deploy | in-place | setup / spend / public | lanes · optional | – | early | watch |
| `evm.eip7702-delegate` | contract | same bytes | **none** | 1 · register | in-place | setup / spend / public | sequence · none | – | early | reject |
| `evm.gnosis-multisigwallet` | vote | own tx → **pointer** | explicit | 1 · deploy | in-place | setup / each vote / public | none · none | a tx | deprecated | reject |
| `btc.p2wsh-sortedmulti` | native | same bytes | implicit | 1 · derive | new-address | spend / spend / public | utxo · none | per sig | production | built |
| `btc.tapscript-multi-a` | native | same bytes | implicit | 1 · derive | new-address | spend / spend / public | utxo · none | per sig | production | built |
| `btc.miniscript-decay` | native | same bytes | implicit | 1 · derive | new-address | spend / spend / public | utxo · none | per sig | production | candidate |
| `btc.musig2-keypath` | aggregate | partial (n-of-n) | implicit | 2 ⚿ · derive | new-address | – / – / public | utxo · none | – | early | candidate |
| `btc.frost-bip445` | aggregate | partial (t-of-n) | implicit | 2 ⚿ · dkg | new-address | – / – / public | utxo · none | – | draft | partial (D) |
| `sol.squads-v4` | vote | own tx → **pointer** | implicit | 1 · deploy | in-place | setup / each vote / public | index · forced (each vote transaction's blockhash lives ~60-90s) | a tx | production | candidate |
| `sol.squads-smart-account` | contract | same bytes | implicit | 1 · deploy | in-place | setup / spend / public | objects · forced (blockhash ~60-90s unless a durable nonce is used) | – | early | watch |
| `sol.spl-token-multisig` | contract | same bytes | implicit | 1 · deploy | fixed | setup / spend / public | dedup · forced (blockhash ~60-90s) | per sig | production | watch |
| `sol.spl-governance` | vote | own tx → **pointer** | implicit | 1 · deploy | in-place | setup / each vote / public | index · forced (voting period + hold-up) | a tx + deposit | production | reject |
| `cosmos.x-auth-multisig` | native | same bytes | explicit | 1 · derive | new-address | spend / spend / public | sequence · optional | per sig | production | candidate |
| `cosmos.x-group` | vote | own tx → **pointer** | explicit | 1 · deploy | in-place | setup / each vote / public | index · forced (voting period, then max execution period) | a tx | production | reject |
| `cosmos.cw3` | vote | own tx → **pointer** | explicit | 1 · deploy | in-place | setup / each vote / public | index · forced (max_voting_period) | a tx | production | watch |
| `dot.pallet-multisig` | vote | own tx → **pointer** | explicit | 1 · derive | new-address | each vote / each vote / public | dedup · none | a tx + deposit | production | candidate |
| `xrpl.signerlist` | native | **own blob each** | **none** | 1 · register | in-place | setup / spend / public | sequence · optional | per sig | production | candidate |
| `stellar.thresholds` | native | same bytes | explicit | 1 · register | in-place | setup / spend / public | sequence · optional | – | production | candidate |
| `algorand.msig` | native | same bytes | explicit | 1 · derive | in-place | spend / spend / public | dedup · forced (<= 1000 rounds) | – | production | watch |
| `tron.permissions` | native | same bytes | implicit | 1 · register | in-place | setup / spend / public | dedup · forced (<= 24h) | per sig | production | watch |
| `hedera.threshold-key` | native | **own blob each** | **none** | 1 · register | in-place | setup / spend / public | dedup · forced (<= 180s) | per sig | production | watch |
| `sui.multisig` | native | same bytes | implicit | 1 · derive | new-address | spend / spend / public | objects · optional | – | production | candidate |
| `aptos.multikey` | native | same bytes | explicit | 1 · derive | in-place | spend / spend / public | sequence · forced (expiration_timestamp_secs) | – | production | watch |
| `aptos.multisig-account` | vote | own tx → **pointer** | explicit | 1 · deploy | in-place | setup / each vote / public | sequence · none | a tx | production | watch |
| `cardano.native-script` | native | same bytes | implicit | 1 · derive | new-address | spend / spend / public | utxo · optional | per sig | production | watch |
| `ton.multisig-v2` | vote | own tx → **pointer** | **none** | 1 · deploy | in-place | setup / each vote / public | sequence · optional | a tx | production | watch |
| `near.multisig` | vote | own tx → **pointer** | implicit | 1 · deploy | in-place | setup / each vote / public | index · none | a tx | deprecated | reject |
| `starknet.multisig` | contract | same bytes | explicit | 1 · deploy | in-place | setup / spend / public | sequence · none | – | production | watch |
| `zksync.native-aa` | contract | same bytes | explicit | 1 · deploy | in-place | setup / spend / public | lanes · none | – | sunsetting | reject |
| `zcash.frost-orchard` | aggregate | partial (t-of-n) | explicit | 2 ⚿ · dkg | reshare | – / – / **shielded** | dedup · forced (nExpiryHeight defaults to 40 blocks) | – | demo | candidate |
| `penumbra.threshold` | aggregate | partial (t-of-n) | explicit | 2 ⚿ · dkg | new-address | – / – / **shielded** | dedup · optional | – | production | watch |
| `monero.multisig` | aggregate | partial (t-of-n) | **none** | 2 ⚿ · dkg | new-address | – / – / **shielded** | dedup · none | – | experimental | reject |
| `aztec.account-contract` | contract | same bytes | explicit | 1 · deploy | in-place | – / – / **shielded** | dedup · optional | – | experimental | watch |
| `mpc.threshold-ecdsa` | aggregate | partial (t-of-n) | explicit | 4 ⚿ · dkg | reshare | – / – / public | sequence · none | – | production | candidate |
| `lez.public-witness` | native | same bytes | **none** | 1 · derive | fixed | spend / spend / public | sequence · none | – | early | candidate |
| `lez.multisig-program` | vote | own tx → **pointer** | **none** | 1 · deploy | in-place | setup / each vote / public | index · none | a tx | demo | built |
| `lez.private-multisig` | vote | own tx | **none** | 1 · deploy | new-address | setup / – / public | index · none | a tx | demo | watch |
| `lez.frost-public-account` | aggregate | partial (t-of-n) | **none** | 2 ⚿ · dkg | new-address | – / – / public | sequence · none | – | draft | candidate (D) |
<!-- landscape-table:end -->

**Gotchas that shape the design.** All are verified; the sources are in the registry.

- **Bitcoin fees are implicit.** BIP-143 commits only to the signer's own input amount, so every signer must re-derive the fee from the previous outputs. A fee bump is a whole new signing round, and for MuSig2/FROST that means new nonces. PSBT bytes aren't canonical, so muster must key on *(unsigned tx, prevouts)* and never hash the PSBT (invariant 5).
- **Bitcoin and Safe signatures never expire.** Cancelling means spending an input or using the same Safe nonce for something else. The card has to say that instead of implying that deleting the proposal withdraws your signature.
- **A Solana blockhash lasts about 60–90 s.** Collecting over hours needs a durable nonce account, which is single-use: anything else that advances it silently kills every collected signature.
- **Cosmos multisig:** the address changes with membership, and even with key order. Any other transaction from the account voids collected signatures. Only amino-json works. The default `TxSigLimit` of 7 blocks multisigs larger than 7 keys.
- **Stellar fails a transaction with an extra signature**, so collection must stop at exactly enough.
- **Safe `operation = delegatecall`** was the Bybit vector (Feb 2025). A card that shows `to` and `value` but hides `operation` and `data` is dishonest. Muster's Safe driver currently maps only `to/value/nonce` (Phase A fixes this).
- **MuSig2 is n-of-n only**, and a reused nonce leaks the key. FROST is true t-of-n. ChillDKG needs authenticated host keys and a relaying coordinator, which is exactly what a muster room is.
- **Maturity flags:**
  - Monero multisig is experimental, and upstream warns a malicious member can steal funds.
  - Zcash `frost-tools` is demo-only.
  - Aztec V5 has a disclosed critical vulnerability.
  - Penumbra Labs has shut down.
  - ZKsync EraVM is retiring.
  - x/group now requires a commercial license.
  - The Logos blog describes a "threshold/MPC multisig", but what shipped in `lez-multisig` is public on-chain voting.

## 4. Downstream consequences for muster, by invariant

| Invariant | What the landscape asks of it | Resolution |
|---|---|---|
| **1** re-derive or refuse | Per-signer blobs (XRPL, Hedera); pointer approvals; PSBT fee re-derivation; Zcash ZIP 312 ("signers MUST compute the SIGHASH themselves" is invariant 1 verbatim) | the materialization becomes **per contributor** (default: the same for all); **declared external reads** are re-read at review time, and a mismatch refuses (S4, S5) |
| **2** env/account/slot/expiry | `binding: none` families; chains with forced expiry | muster's envelope always commits. The card classifies chain-layer binding: explicit/implicit is *imperative*; none is *exposed* (party: whoever holds the signature on another network). Forced chain expiry maps onto the envelope's `expiry` field |
| **4** state = reduce(log) | Aggregate schemes carry secret nonces between rounds; vote families keep state on the chain | Secrets never enter the log. The log holds commitments and partials; a nonce is a **keystore operation** marked consumed before release (S7). Chain state enters only through recorded external reads, so the room's view is reduce(log) plus attested reads |
| **5** deterministic bytes | PSBT, amino JSON and Solana messages are not canonical as carried | canonical forms are dCBOR of the *semantic* input (e.g. unsigned tx plus prevouts). The foreign encoding is an interop codec, never a hash input |
| **6** the core never interprets | Rounds, DKG, per-vote transactions | all driver-described (the profile). The core routes on `profile.locus`, never on a policy string or concrete type |
| **7** membership epochs | **Two sets:** room members (who can read) and signers (who can authorize) | shown separately. A signer outside the room is a *foreign signer* (interop); a member who isn't a signer is an observer. A key ceremony share is per person and never comes from room admission |
| **8** no server | Each family's usual coordinator is a server: Safe Tx Service (API key, proposals world-readable before execution), Refractor, Liana Connect (sees your addresses), frostd (an untrusted relay that can't enforce end-to-end encryption), Nunchuk's relay (keyed by a PBKDF2 of the descriptor) | **the room replaces all of them.** Interop exports happen only on an explicit user action. RPC, UTXO source, bundler and mirror node are user-configured and appear only when a proposal needs them (exo-428) |
| **10** provenance | nonce, UTXOs, blockhash, sequence, on-chain proposal content | every read that reaches signed bytes is recorded as `external-read` with its log position and source; signing refuses an unrecorded read |

**Positioning.** For native, contract and aggregate families, the *collection* step is exactly where every other tool either runs a server or falls back to files and QR codes. An encrypted, epoch-keyed, authenticated room with a client that re-derives before it signs is the coordinator these families lack. For aggregate families it's more than a convenience: ChillDKG's security assumes the authenticated channel and relay a room already is. The education claim follows directly: *the same room, whatever the multisig; where the multisig itself leaks, the card says so.*

## 5. Strategy: family = scheme × settlement, account = a family instance

### Three layers

- **Family** (registry entry, static). A way a group can hold an account: `evm.safe`, `btc.p2wsh-sortedmulti`, `sol.squads-v4`, `btc.frost-bip445`. It carries the profile: the dimensions in §2.
- **Driver** (code, one per family *shape*). Implements the `Driver` seam. It is built from two reusable parts:
  - a **scheme**. There are only five: same bytes, a blob per signer, own transaction, aggregate n-of-n, aggregate t-of-n. The scheme decides what a contribution is, how many rounds there are, and how to verify.
  - a **settlement** on a chain adapter, about 20 of them (none, evm, bitcoin, solana, cosmos, …). The settlement builds the signable bytes from the effect plus declared reads, assembles contributions into a chain transaction, submits it, and watches finality.
- **Account** (room log object, dynamic). A family made concrete: CAIP-2 chain, CAIP-10 address (or a descriptor), signer set, policy, config. This is what the prototype already calls an account ("accounts = drivers") and what the UI shows everywhere.

This turns the family × chain matrix into a sum. FROST-secp256k1 is one scheme serving `btc.frost-bip445` and `lez.frost-public-account`. `evm.safe` on Base versus on Ethereum is one family with two accounts. Adding XRPL is a settlement plus the per-signer-bytes scheme, which is also Hedera's.

### Seam changes (all proposed)

| # | Change | Why | Replaces today |
|---|---|---|---|
| **S1** | **Accounts live in the room, disclosed by members**: `account/<id>/disclose {family, chain, address, signers, policy, config}`, authored by a named member (ADR-015). An account exists to the room only once a member discloses it. Every reader checks the disclosure against the chain (an external read, invariant 10) and the room shows who disclosed it and whether the chain agrees. Create means a setup proposal whose result is disclosed. The local catalogue still records which disclosed accounts *I* can sign for | a multisig manager manages *accounts*; this also answers exo-1ec.4's config scope with "per room, in the log, by disclosure" | the `gDriver` global, `SAFE_ADDR`, `environment: "anvil-31337"` |
| **S2** | **One kind list**: family id → driver constructor, in `registry.nim`, validated against the registry file. An unknown kind *refuses* | there are four disagreeing lists today, and `driverForKind` silently falls back to the Safe, which is a guess | `driverForKind`'s `else: gDriver`, `roomDriverKinds`, `policiesForKind` |
| **S3** | **`Driver.profile()`**: the family's profile, filled in for the instance (k, n, chain, address, bypasses read from the chain). Conformance checks that it matches the registry entry and is consistent with `describe()` and `manifest()` | the card's slots and the phrasebook read it; no consumer branches on concrete type (the null-ladder rule) | `drv of SafeDriver` in `live.nim` and `muster_module.nim` |
| **S4** | **`materializationFor(effect, contributor)`**, defaulting to `canonicalize(effect)` | per-signer families (XRPL, Hedera) | — |
| **S5** | **`reads(effect)`**: the external state the bytes depend on (nonce, prevouts, blockhash or durable nonce, on-chain proposal content, sequence). Re-read at review and at settle | invariants 1 and 10 for implicit bindings and pointer approvals | the ad hoc `safeNonce` read in the composer |
| **S6** | **Settlement seam**: `assemble`, `submit`, `watch` on the chain adapter; the core routes on `profile.locus`. In a vote family a contribution *is* a chain transaction the signer submits, and muster verifies it by reading the chain | settlement is currently routed by `policy == "safe"` / `"invoke"` strings, and drivers and adapters never meet | `coordinate_submit`'s Safe-only body, `liveSubmitPrecheck` |
| **S7** | **Round secrets as keystore operations**: `nonceCommit(session)` and `partialSign(session, msg)`, with the nonce marked consumed before it is released. After a crash the session aborts; a nonce is never reused | MuSig2 and FROST: a reused nonce leaks the key | — |
| **S8** | **Interop codecs**: `exportSignable(format)` and `importContribution(format, bytes)` for PSBT, Safe Tx Service JSON, `spl-token --sign-only` pairs. An imported contribution is verified exactly like a native one | foreign signers (Keycard Shell, Coldcard, Sparrow) | — |
| **S9** | **CAIP-2/CAIP-10 everywhere**, and **one finality enum** (`immediate · probabilistic · delayed · external`) shared by drivers and adapters | the chain is spelled five ways today (`eip155:`, `chain:`, `evm:`, `anvil-31337`, `lez:`) and there are two finality enums. Namespaces with no CAIP entry (`lez`, `monero`, `aztec`) are ours to propose | the ad hoc spellings |
| **S10** | **Card copy from the phrasebook** (§6.3) | the card currently says "Proposed a payment", ends in "paid", has a static "chain does not enforce it" caveat, and a Safe-only `verifyDomain` | the Safe-specific QML strings |

Conformance grows with S3: a driver whose profile contradicts its registry entry or its own `describe()` fails. For example, `locus: aggregate` with one round, or `settlement: none` with external finality. That matches how the manifest's `consistencyFailures` works today.

## 6. The UI contract: obvious, and the same

### 6.1 Accounts are first-class

- **An account enters a room when a member discloses it.** The chip names who disclosed it and whether the chain agrees with the disclosure (verified · disagrees · couldn't check).
- **The account chip** appears on the room header, the composer and every card: `Ops Treasury · Safe on Base · 2 of 3`, with a maturity badge when it isn't `production`.
- **Add a shared account** goes: *which chain* → the registry lists the families available on that chain, each as five plain lines (where the rule lives, who sees what, what approving costs, setup, maturity) → *import existing* (address, descriptor, or a chain read) or *create new* (deploy, derive, or a key ceremony in this room). Families marked `watch` or `reject` still appear, greyed out, with their `why`. Showing a non-option honestly is part of the education.
- A room can hold several accounts. Each proposal names its account (the policy is already per intent).
- **Signers outside muster are surfaced, never implied.** Only families with a standard interop format (`interop` in the registry: PSBT, Safe Tx Service JSON, …) offer them. The chooser says whether a family allows outside signers, and the card marks each outside signer's slot with the format they sign through.

### 6.2 The card has fixed slots

```
┌ Ops Treasury · Safe on Base · 2 of 3 ─────────────────── [production] ┐
│ Send 1.5 ETH to 0x7099…79C8                                           │
│ proposed ─ collecting ─ ready ─ submitted ─ final                     │
│            └ round 1 of 2: commitments   (only multi-round families)  │
│ Approvals  ● Alice   ○ Bob   ○ Carol (signs outside muster · PSBT)    │
│ ─ How this account works ──────────────────────────────────────────── │
│  Where the rule lives   A contract on Base checks 2 of 3 signed.      │
│  What you sign          The full action. Muster rebuilt it: match.    │
│  Only valid on          Base (chain id in the signed domain).         │
│  Ordering               Action #47; it settles after #46.             │
│  Expiry                 Never. To cancel, use #47 for something else. │
│  Who will see what      the room · store node · RPC · the chain: …    │
│  Approving costs you    Nothing. Whoever submits pays the gas.        │
│  Changing signers       A proposal on this account; the address stays.│
│  Ways around the rule   None known (modules read from chain: none).   │
│ ─ What this needs ─ (the manifest box, as today) ──────────────────── │
└───────────────────────────────────────────────────────────────────────┘
```

- **The same rows in the same order for every family.** A family that has nothing to say for a row says it plainly ("Nothing leaves this room"). Rows are never dropped.
- **The status rail never changes.** Family specifics become sub-steps *inside* a state: rounds, on-chain votes, a durable nonce being advanced. They never become new top-level states.
- **Each row carries its credibility class** from `action-manifest.md` §2: imperative, motivational or exposed, with the party named. A bypass *is* a defection path, which feeds exo-3ae's defection facet.

### 6.3 The phrasebook (what makes it feel the same)

Each row reads from one closed-vocabulary value, filled with instance facts. Same slot, same sentence shape, different truth:

| Row | Value → sentence | Credibility |
|---|---|---|
| Where the rule lives | native → "The {chain} protocol itself checks {k} of {n} signed." · contract → "A contract on {chain} checks {k} of {n} signed." · vote → "Each approval is its own public transaction on {chain}; the chain counts them." · aggregate → "The {k} signers combine into one signature. {chain} sees one signer and learns nothing about the group." · room → "Agreement is final in this room. Nothing goes to a chain." | imperative, unless bypasses exist |
| What you sign | content/shared → "The full action; muster rebuilt it and it matches." · per-signer → "Your own copy (your account is part of it); muster rebuilt yours." · pointer → "A pointer to proposal #{i} on {chain}; muster read it at block {h} and it matches." | pointer: motivational (party: RPC provider), or imperative with a verified read (F-10) |
| Only valid on | explicit → "{network} ({via})." · implicit → "Only where these exact {coins/objects} exist." · none → "Any {chain} network would accept it. Muster binds it to {network} here; the chain does not." · room → "Nowhere outside this room." | none → **exposed** |
| Ordering / expiry | sequence → "Action #{n}; it settles after #{n−1}. Anything else from this account first makes it stale." · utxo → "Spends these coins; another proposal spending them conflicts." · forced → "Signatures expire {window}." · none → "Signatures never expire. To cancel, {cancel}." | as the chain enforces |
| Approving costs you | none / per-signature / per-vote / per-vote-deposit → "Nothing" / "Each signature adds to the one fee" / "A transaction you pay for (~{fee})" / "…and the first approver locks {deposit}" | imperative |
| Changing signers | in-place → "A proposal on this account; the address stays." · new-address → "A new account; funds move in a second proposal." · reshare → "A key ceremony in this room; the address stays." | — |
| Ways around the rule | "None known" · a list read from the chain · "Unknown: muster couldn't read the account's modules" | a bypass is motivational, with the party named |

## 7. The registry

- `contracts/families/registry.json`: `about.vocabulary` is the closed set, and `families[]` holds one entry each. The fields match §2. `muster.status` is one of `built · partial · next · candidate · watch · reject`, always with a `why`.
- `scripts/check-family-registry.py` validates:
  - the vocabulary;
  - that the fields tell one story, e.g. aggregate ⇒ nothing revealed on-chain, vote ⇔ own transaction ⇔ per-vote cost, pointer ⇒ vote, secret state ⇒ ≥2 rounds, key ceremony ⇒ t-of-n aggregation;
  - that built/partial drivers exist on disk;
  - that forced expiry has a window;
  - that every planned `binding: none` family names its exposure.
- It warns on every `unverified` item so they stay visible.
- It will become the source for the account chooser (§6.1) and for S2's kind list. Nothing reads it at runtime yet.

## 8. Order of work

Each phase proves one new locus with the fewest new seams, and uses real signers.

| Phase | Families | Proves | Seams | Exit test |
|---|---|---|---|---|
| **A** | `evm.safe`, done properly | accounts, profile, settlement seam, card copy; no globals | S1, S2, S3, S6, S9, S10, plus Safe fidelity: `data`/`operation` mapped and shown (delegatecall warned), the real 1.5.0 singleton, bypasses read from the chain (modules, guard) | two Safes on two chains in two rooms; the card rows come only from `profile()` |
| **B** ✓ | `btc.p2wsh-sortedmulti` + `btc.tapscript-multi-a` | native locus, UTXO ordering, no expiry, **foreign signers** | S4 (default), S5 (prevouts), S8 (PSBT) | a Keycard Shell cosigner signs a PSBT over QR next to a muster member; the two families' cards differ only in *Who will see what* — **landed 2026-09-24, see below** |
| **C** ◐ | `lez.multisig-program` | vote locus on Logos's own chain; pointer approvals; per-vote cost; an `exposure` row | S5 (on-chain proposal read), S6 (a contribution is a chain transaction) | approving in the room submits the member's LEZ vote; the card says every approval is public — **core landed 2026-09-24, live chain blocked upstream, see below** |
| **D** | `btc.frost-bip445` + `lez.frost-public-account` | aggregate locus, the key ceremony in the room, looks single-sig | S7; replaces the `frost` scaffold | a 2-of-3 in-room ChillDKG, then a spend the chain can't tell from single-sig. Includes the LEZ tweak check (§9, Q5) |

**Phase B, as it landed (exo-a50.2, 2026-09-24).** `btc_regtest_e2e` runs both families against Bitcoin Core v31.1 on regtest:
- Core derives the same address from the descriptor.
- The spend is built from the UTXOs the node reports.
- A member approves in-app through the keystore (attested).
- The outside signer is a **Bitcoin Core wallet**, which signs muster's exported PSBT. The signature is imported, counted, and graded unattested.
- Core accepts muster's finalized witnesses, and the spend is final a block later.

Two corrections to the plan above:
- A **Keycard Shell** cosigning over QR is the same PSBT round trip, but it has not been run on the device.
- The cards do **not** differ in *Who will see what*. A single-leaf tapscript multisig reveals what P2WSH does at spend, the policy and the signers, because the one leaf *is* the whole policy. Its hidden-branch advantage appears only with more leaves (`btc.miniscript-decay`). The rows are identical, and the profiles differ only in family and account.

**Phase C, as far as it landed (exo-a50.3, 2026-09-24).** `phase_c_exit_test` passes against an in-process model of `lez-multisig` (`FakeLezMultisig`), which reproduces its handlers and stores the program's own borsh accounts at their PDAs. For a 2-of-3:
- The account is disclosed with its config, and the room re-derives the state PDA and reads the chain.
- Proposing is the proposer's own Propose transaction.
- A member approves in the room: muster re-reads proposal #i (S5), casts the member's own vote transaction through their LEZ wallet, paid from their payer account, and confirms it by reading the chain back.
- A pointer to different on-chain content is refused before any vote.
- Settlement counts the votes on chain and Executes.
- The card says every approval is a public transaction and the binding is exposed.

Two findings:
- **The program cannot run on the chain muster talks to.** It targets nssa v0.2.0-rc3, whose PDAs hash `/NSSA/v0.2/…` over the image id; `lez_core` 0.4.x speaks LEE v0.2.5 (`/LEE/v0.2/…` over the program's account id). The program's guest derives PDAs with its own linked core, so it must be rebuilt upstream before a live run (exo-3c9; `docs/labbook/lez-multisig-versions.md`).
- **Member accounts must be fresh** when the multisig is created, because the program claims them. Every member therefore needs a separate funded payer account for their vote fees, which is the per-contributor readiness the vote-cost decision (§9) anticipated.

After D, by demand: `xrpl.signerlist` (per-signer bytes), `sol.squads-v4`, `cosmos.x-auth-multisig`, `sui.multisig`, and `zcash.frost-orchard` once its tooling leaves demo status. The privacy flagship shares Phase D's scheme with a different ciphersuite.

**Why this order:**
- A is the prerequisite for everything.
- B brings in foreign signers early, and Keycard Shell 1.4 already cosigns P2WSH multisig with stored descriptors, which is a Status and Logos synergy that exists today.
- C puts the vote locus on our own chain, through a module already bundled (`lez_core`).
- D is the highest-value and hardest phase: secret state, a key ceremony, and draft BIPs. It is also ADR-015's remedy, "an aggregate-signature rail", for the one leak ADR-015 names: Safe settlement naming its signers to chain observers.

## 9. Decisions (2026-09-23)

| Question | Decision |
|---|---|
| Account scope | **Accounts live in the room, as disclosed by members.** A member discloses an account into the room log; readers verify it against the chain; the room names who disclosed it (S1, §6.1). |
| Signers outside muster | **Yes, where it makes sense, and always surfaced.** Only families with a standard interop format; the chooser and the card say so (S8, §6.1). |
| Families with `binding: none` | **Accept, with an `exposure` row on the card.** For LEZ, push for a zone/domain tag in the public message upstream. |
| Vote-locus costs | **Each voter pays their own vote transaction for now**, so every member of a vote-locus account needs a funded chain account; readiness grades it per contributor. Revisit a user-configured relayer later. |
| The LEZ aggregate-key assumption | **Accepted as the working assumption for Phase D.** It stays in the registry's `unverified` list until a Phase D test proves it. |
| Threshold ECDSA (MPC) | **Candidate.** Muster isn't production code, so prototype-grade libraries are acceptable now. **Production gate:** before real transactions and users, re-choose the library for license, CVE history and identifiable abort. |
