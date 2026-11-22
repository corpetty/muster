# RFP-005 roadmap: the multisig, the program and the room

*Draft, 2026-11-17; revised 2026-11-20 after the team's feedback (§0). For Franck, the EcoDev engineer who will dogfood it, and IFT-QA. Owner:
Corey Petty. Tracked as exo-0d3 (epic) and exo-0d3.19 (this document); new items exo-0d3.20 (Ed25519 members), .21 (T1), .22 and .23 (T2).*

Muster takes RFP-005 ([the spec](https://github.com/logos-co/rfp/blob/master/RFPs/RFP-005-multisig-and-coordination.md))
under the usual RFP process. A dedicated EcoDev engineer drives each milestone: they announce it,
dogfood it, give feedback and sign it off. IFT-QA runs the acceptance scripts, the R&D Program team
reviews the program, and the program goes on the audit track. This document lists what is done,
what comes next, and the two scope changes agreed since 2026-11-11.

The program was the RFP's largest unknown, and it is already written and measured. The work left is
mostly productising it: the LEZ 0.4 port, a standalone module and CLI for integrators, the registry
and the documentation, and the audit.

## 0. Feedback, 2026-11-20, and what changed

| Point raised | Answer, and what this revision changes |
|---|---|
| The devnet is LEZ **0.4.0-rc3** (`46.225.45.199:3040`–`3043`, channel `d616cc09…615d`) | It answers from the build host. The 0.4 port is therefore no longer a later milestone: it **is** M1. The public posture already runs on a local 0.4.0-rc3 zone (PR #387). A devnet funder account is made and waits for funds (Q2). |
| The registry program (F.4) has no taker on the LP: are we blocked? | **No.** Our F.4 is a registry of program descriptors in Muster's signed package, each keyed by program and image id and cross-checked against the chain's deployment header. It needs no on-chain registry. Decode-before-sign already covers the multisig's own actions. An on-chain registry, if the LP lands, becomes a second source the client reads. |
| The `chat_module` binding waits on member removal; do it earlier to de-risk | Removal is in review (logos-chat PR #357, GroupV3 removals). The binding moves from M6 to **M3** as a limited integration first: each multisig's **deliberation** runs over a `chat_module` group whose membership follows the program's, while proposals and approvals stay on Muster's room until the binding reaches parity. Known limits are in §5. |
| The L1 multisig: David to define the plan | §1.2 and §4 no longer propose a mechanism. The channel-as-treasury questions are removed: we wait for the Blockchain team's strategy, likely programmable UTXOs in 0.5 (possibly 0.4). T1 stays tentative. |
| The shared secret can't be revoked: is migration the accepted practice? (James Zaki, zone team) | James's 0.4 multisig (`jzaki/jz-progs`, `example_progs/multisig`) rotates **in the program**. The approval that removes a member retires the vault, hands its config to a successor at a new PDA from a new group secret, and moves the whole balance there, all in one transaction. `lez-msig` adopts the same on 0.4 (D19): removal becomes one approved action, never a separate migration. |
| Seats or signatures | The LEZ book (`catalog/multisig.md`, branch `moudy/lez-books`) lists "signatures instead of seats" as the alternative: one transaction per action, at the price of signature checks in the guest. `lez-msig` keeps signatures, because seats cost k private transactions, each a proof of minutes. It takes rotation from the seat design. |

## 1. Scope, as changed

### 1.1 Three layers, each usable without the others

Integrators want different subsets (fryorcraken, 0xGunner, 2026-11-16). BitGo uses a chain's own
multisig program where one exists. Finoa and the large custodians (Fireblocks, Copper, Anchorage)
put one key on chain and run approvals in their own MPC. Our own treasury and community wallets
go through Muster. So the deliverable is split into three layers with documented seams:

| Layer | What it is | Who uses only this layer |
|---|---|---|
| **1. The program** | `lez-msig`: M-of-N enforced by the LEZ program, which verifies BIP-340 approvals at execution. It has no opinion on how approvals were collected. | Integrators with their own transport and signing (option 2: BitGo) |
| **2. The signing seam** | A written spec of what an approval signs (a tagged digest committing to zone, account, config epoch, nonce, action and expiry), with test vectors. A signature from an HSM, an MPC cluster or a keystore all count the same. | Anyone who brings their own signers |
| **3. The coordination room** | Muster: an encrypted room where members deliberate, the card decodes the exact bytes before signing, and approvals are collected off-chain. | Logos treasury and community wallets, DAOs, circles, Monero groups |

Option 1 (one key on chain, MPC elsewhere) needs no multisig program. It needs LEZ and L1 account
schemes that custodians' MPC stacks can sign. Those stacks sign Ed25519 and ECDSA, while LEZ
accounts and `lez-msig` approvals use BIP-340 (§4.3). That gap matters more than any other for
integrators. Muster already has the in-house version of option 1: a FROST group owns a plain LEZ
public account with one aggregate key (`drivers/lez_frost.nim`, `lez_frost_room_e2e`).

Today layers 1 and 3 are separate code (`programs/lez-msig/`, `module/`), but the only full client
of the program is Muster's room. Milestone 2 makes the program usable on its own.

### 1.2 The Logos blockchain (L1) multisig: added, owned by the Blockchain team

The Blockchain team builds the L1 multisig (Ksr, 2026-11-16), and David will share its plan. The
likely basis is the programmable UTXOs coming with 0.5 (possibly 0.4).

Muster's part is coordination: a driver family for whatever they build, the same room, the same
decode-before-sign card. It is a **tentative milestone** (T1), and it starts once their design is
fixed. §4 keeps only what bears on integrators' key schemes.

## 2. Where it stands

Built on `main` (PR #344 and follow-ups), released as Muster 0.3.3 with `lez_msig_module` 0.1.0 in
Muster's own catalogue. Design and decision log: `docs/design/lez-msig.md`.

- **The program** (`programs/lez-msig/`, LEZ v0.3 `run_program(plan, apply)`). The rules live in
  `msig_core`, a pure crate with thin runtime adapters. One program serves both postures: over a
  public PDA, or over a group-owned private PDA. It has been run on a live v0.3 sequencer: a
  private multisig was created, funded and paid out 2-of-3, and nothing public exists at its id.
- **The room flow.** A multisig is opened from a Muster room. A ceremony binds each member's
  approval key to their room identity. Proposals, approvals and execution happen in the room. The
  card decodes the exact bytes each approval signs. This was run end to end against the deployed
  program and through two real Muster clients on screen. The private posture also runs from the
  room: the prover is the `lez_msig_module` Rust module, the group secret is sealed per member,
  and lost notes are recovered by scan. So far this has run in dev mode only.
- **The cost question is answered** (`programs/lez-msig/BENCHMARKS.md`, real proving, 64 cores).
  A private payment with M approvals proves in 151 s at M=1, 209 s at M=5 and 288 s at M=10,
  about 15 s per approval. The transaction stays a constant 228 KB. M ≥ 5 is viable.
- **The same client already coordinates other multisigs:** a Safe on Sepolia, Bitcoin through
  PSBT, the vote-locus LEZ multisig, FROST on Bitcoin and LEZ, and Monero multisig.

### 2.1 Requirement by requirement

✅ done · 🟡 partial · ⬜ not started · ↪ deliberate deviation

| Req | | Status |
|---|---|---|
| F.1 M-of-N, configurable members, threshold, action set | ✅ | `msig_core`, `rules.rs` tests |
| F.2 lifecycle, expiry, off-chain collection, no payload in the clear | ✅ | approvals are collected in the room and verified in-program |
| F.3 arbitrary program calls | ✅ | `Call` action; the room composer proposes calls |
| F.4 proposal/target registry | ⬜ | designed (descriptors in Muster's signed package, keyed by program + image id); not blocked on an on-chain registry; M4 |
| F.5 config changes through the quorum | ✅ | program ✅; the room follows the program's members and config (exo-0d3.13, PR #382) |
| F.6 role separation | ✅ | PROPOSE / APPROVE / EXECUTE, guarantees in the design |
| F.7 time lock | ✅ | validity windows; ETA is pessimistic |
| F.8 spending limits | ✅ | program ✅; adding a limit and spending under it from the room (exo-0d3.12, PR #383, e2e against the real program) |
| F.9 E2EE room per multisig, LEZ↔chat binding | ✅↪ | Muster's room, not `chat_module` (S.2 below) |
| F.10 private default, public posture, selective disclosure | 🟡 | both postures ✅; disclosure tiers designed, not built (M4) |
| U.1 a module other modules call | 🟡 | `lez_msig_module`: the prover plus the public posture's key-free operations (PR #385); the private posture's full API is still Muster's |
| U.2 QML mini-app in Basecamp, room beside proposals | 🟡 | Muster in Basecamp via its catalogue; a dedicated multisig view is M4 |
| U.3 CLI on the headless core | 🟡 | `msig_exec` covers the public journey (PR #385, README); a `logoscore` wrapper is still to do |
| U.4 IDL via SPEL | ⬜ | SPEL is thinning under 0.4; M3 decides SPEL or its successor |
| U.5 per-action public/private documentation | 🟡 | design §7; the operator-facing table is M4 |
| U.6 decode before signing | 🟡 | ✅ for the multisig's own actions; arbitrary targets wait on F.4 |
| U.7 actionable errors | 🟡 | refusal codes exist; a UI pass in M4 |
| R.1 M distinct current members, exactly this action, no replay | ✅ | `rules.rs`, `v03_state.rs` |
| R.2 config change invalidates old approvals, cutoff defined | ✅ | config epoch; the cutoff is the queue; immediate cancel |
| P.1 CU, size, proving time per operation | 🟡 | measured on v0.3 on a shared machine; rerun idle, on a laptop, and on 0.4 (M1, M3) |
| P.2 cost as a function of M, M ≥ 5 viable | ✅ | ~12 s per approval on an idle 64-core machine (PR #385); rerun on 0.4 |
| S.1 LEZ, private accounts | ✅ | |
| S.2 the room on `chat_module` | ↪ | removal is in review (logos-chat #357); a limited integration (deliberation) is M3, the full binding M6 |
| S.3/S.4 testnet 0.4, deployed there | 🟡 | deployed on the 0.4.0-rc3 devnet; the public posture runs there (PR #387); the private posture is M1 |
| S.5/S.6 e2e against a standalone sequencer in CI, green | 🟡 | a workflow runs them on a local v0.3 zone (PR #386); 0.4 follows the port |
| S.7 a test per hard requirement | 🟡 | below-threshold, R.2 and drain-before-create are covered; the full mapping is M4 |
| S.8–S.10 README, API, CLI docs | 🟡 | M2 (API, CLI), M4 (README) |
| S.11 designs | 🟡 | `ui/prototype/desktop-v3.html`; M4 |
| S.12 own catalogue | ✅ | `catalog/`, `lez_msig_module` 0.1.0 |
| S.13 audit programme | ⬜ | M5 |
| S.14 decision log | ✅ | design §9, D1–D12 |
| Privacy 1–3 | 🟡 | documented in design §7; checked on chain for the private payment; the cross-layer correlation write-up is M4 |
| Soft: weighted approvals | ✅ | |
| Soft: proof of holding | ⬜ | out of scope unless funded as research |
| Soft: mixed postures | ⬜ | not planned |

## 2.2 Progress since this draft

Work done while waiting for feedback, each item in its own draft PR:
- **M1: the room follows the program's member set** (exo-0d3.13, PR #382).
  - The room's copy of the config folds executed config changes.
  - A removed member is re-keyed out, once.
  - A private multisig's added member gets the group secret.
  - Queued actions by a removed member are flagged beside their cancel.
- **M1: spending limits from the room** (exo-0d3.12, PR #383). A limit is added through the
  quorum, and a spend under it goes as one Spend, with no quorum and no time lock. It was run
  against the real program on a local LEZ v0.3 zone.
- **M2: the signing spec** (PR #384, `docs/design/lez-msig-signing.md`). It says what an
  approval signs, for integrators without Muster.
- **M2: the program stands alone** (PR #385). `lez_msig_module` and the `msig_exec` CLI gain
  key-free public-posture operations: state, propose, spend, check, prepare and send. The
  program's README documents the whole no-Muster journey. It ran against a real sequencer with
  every key outside the module.
- **M1: the benchmark rerun on an idle machine** (PR #385, `BENCHMARKS.md`), with real proving:
  - a private payment proves in 125.5 s at M=1, 170.6 s at M=5 and 232.0 s at M=10;
  - that is about 111 s + 12.0 s per approval;
  - the transaction is a constant 228 KB.
- **M1: a private multisig with real proving, from a room** (PR #386). `localnet.sh` starts a zone
  that verifies real receipts. On it, all nine sections of the private-room e2e passed, with every
  transaction really proved (765 s on 64 cores). The same PR adds the lez-msig e2e to CI
  (S.5, S.6).
- **M1: lez-msig on LEZ 0.4** (exo-0d3.9, PR #387).
  - The actor adapter runs over the same `msig_core`, in its own workspace.
  - Public posture: 5/5 on LEE's v0.4 state, and a live run on a local 0.4.0-rc3 zone (create,
    2-of-3 pay, every transaction paying its fee).
  - `localnet.sh` runs 0.4 zones.
  - Decisions D13–D16 are taken; D17 and D18 are proposed.
- **M1: on the 0.4 devnet** (2026-11-20, PR #387).
  - lez-msig deployed immutable at `2tTh5nUpBxtTAoQBCQbzmG32JGapm2KaEpH9oxktGanG`.
  - The public posture passed there: create on a fresh PDA, a refusal below threshold, a 2-of-3
    payment.
  - Muster's own client drives the multisig on a local 0.4 zone, 7/7.
  - Measured at base fee 8: Create ≈ 0.83M, a 2-of-3 Execute ≈ 4.7M. **A refused transaction
    burns its whole declared gas limit**, so Muster's sends need per-step limits (exo-50c).
- **M3: chat_module, limited** (PR #388). Each multisig's discussion runs in a chat group that
  follows its members. With a patched module exposing `remove_group_member`, removal was proven
  on the live fleet: the removed member reads nothing after.
- **M1: Muster's own client on the devnet** (exo-50c, PR #387). Every step declares a gas limit
  fitted to what it meters, so a refusal no longer costs about 16M. Muster's three-member room
  flow passed 7/7 against the devnet program.
- **M1: the private posture on 0.4** (exo-05f, PR #387), 2026-11-21:
  - **D17 decided:** every private transaction pays its fee inside its proof from a group fee
    account derived from the GMS, witnessed `FeeOnly`. Members top it up from a public account in
    one proof that pays its own fee out of the credit, so a group needs no funds to start.
  - **D18 decided:** the program is deployed immutable and proved undisclosed; a transaction
    names no program.
  - On the devnet with real proofs: top-up, Create, deposit and a 2-of-3 payment (104 s, 257 s,
    233 s and 292 s to prove), each fee about 5.7M.
  - **Through Muster's real UI on the devnet** (two runners, real proofs): a private 2-of-2 was
    opened, topped up, created, funded, approved on the card and settled, in 925 s end to end.
- **M1: the 0.4 prover as a Logos module** (exo-cc7, PR #387). `lez_msig_module` 0.2.0 is built
  from the 0.4 workspace and loads in `logoscore`. Muster takes the prover that matches the zone's
  line and names the version to install when it doesn't. The UI has "Top up the fee account".
- **M1: P.1/P.2 on 0.4 with real proving** (`BENCHMARKS.md`, 64-core EPYC):
  - a payment proves in about 182 s + 11.5 s per approval (v0.3: 136 s + 15 s);
  - paying the fee inside the proof costs about 95 s on every step;
  - the transaction is 229–238 KB, flat in M.
- **M1: a private payee and a private Call** (PR #387). Both run on LEE's 0.4 state, and the private
  payee also on a local zone. A private payee's credit is sealed to it, and it alone opens and
  claims it. A Call runs with the vault's seed inside the proof.
- **Reports to the teams** (`docs/upstream/`): LEZ (costs, latency, and nine findings with asks),
  chat (removal, addresses, membership timing), and the module builder (packaging).
- **Not done:**
  - D19, in-program rotation (exo-3dc);
  - a private payee from the room (exo-ea3);
  - deposits from outside the group arriving as sealed messages;
  - a laptop-class benchmark;
  - the Basecamp dogfood journey;
  - `lez_msig_module` 0.2.0 in the catalogue.

## 3. Milestones

Each milestone ends with an **acceptance script** IFT-QA can run, and a **dogfood journey** the
EcoDev engineer does by hand. Sign-off is on both. Week estimates assume one engineer (Corey),
starting 2026-11-23. Milestones 2 and 3 can overlap.

### M1: on the 0.4 devnet (4 weeks, to ~2026-12-18)

The devnet runs LEZ 0.4.0-rc3, so M1 is the 0.4 port (exo-0d3.9), deployed where people can reach
it.
- **Public posture on 0.4:** done, on the devnet, and from Muster's room (PR #387).
- **Private posture on 0.4**, on top of the decisions in `docs/design/lez-msig.md` §9:
  - **D17:** the fee every private execution now pays inside the proof. Decided and done.
  - **D18:** the program deployed immutable and proved undisclosed. Decided and done.
  - Deposits from outside the group, arriving as sealed messages that the next execution
    collects. Not done; members deposit inside the proof today.
  - The new private addresses. Done.
- **In-program rotation (D19):** removing a member is one approved action. In that transaction the
  vault moves to a successor under a new group secret, carrying its config and balance. A retired
  vault forwards late deposits (a sweep). This is James Zaki's pattern, and it answers the
  revocation question.
- **Muster's client on 0.4:** the transaction codec, the chain seam and the prover module. Done,
  and run through the real UI on the devnet.
- **Already done for v0.3:**
  - the room follows the program's members (#382);
  - spending limits from the room (#383);
  - real proving from a room (#386);
  - the idle benchmark (#385).
- P.1/P.2 rerun on 0.4 with real proving (done, 64-core EPYC), and on a laptop-class machine (not
  yet).
- **Dogfood:** install Muster in Basecamp. Two people open a 2-of-3 private multisig on the
  devnet, fund it, pay out, add a member, remove one (the vault rotates), and watch the removed
  member lose the room.

### M2: the program stands alone (3 weeks, to ~2026-12-23)

This is the program/protocol separation.
- `lez_msig_module` grows from a prover into the multisig module (U.1): create, propose, approve,
  reject, execute, config changes and limits, with progress events while a proof runs. It needs
  no Muster room. Muster becomes one client of it.
- A CLI over `logoscore` (U.3) covers the operator journey.
- **The signing spec:** the approval digest, the encoding of proposals, and test vectors
  (`msig_vectors`). An external signer (an HSM, an MPC cluster, a hardware wallet) can produce a
  valid approval from it without our code.
- A "bring your own transport" integration guide (S.9, S.10). Approvals travel however the
  integrator likes; the program is the only authority.
- If Q6 confirms it: **Ed25519 member keys** alongside BIP-340, each member declaring its scheme,
  so a Fireblocks- or Fordefi-held key can approve (§4.3). Its cost per approval is benchmarked
  with real proving.
- **Dogfood:** the full journey from the CLI alone, with one approval produced by a script outside
  Muster from the spec.

### M3: `chat_module`, early and limited (2 weeks, overlapping M1)

Moved up from M6, to de-risk S.2.
- **Deliberation first.** Each multisig's discussion runs over a `chat_module` group conversation,
  whose membership follows the program's. Adds and removals use logos-chat PR #357.
- **Machine coordination stays on Muster's room for now.** Proposals and approvals stay there until
  the binding behind `ConversationCrypto` reaches parity: forward secrecy on removal, a store node
  that cannot read membership, and an exportable proof.
- What the spike measures:
  - removal end to end, including what a removed member still sees;
  - the room id on the wire;
  - the key-package service.

  Each gap is reported to the chat team with a test.
- **Dogfood:** the devnet multisig's members talk in its chat group, and a removed member drops out
  of it.

The IDL (U.4) and the 0.4 CI move with the 0.4 work. The IDL comes through SPEL if it still makes
sense under 0.4, otherwise through James Zaki's tooling. The audit's code freeze follows M1 and M2.

### M4: decode, disclose, document (3 weeks, to ~early February)

- The target-program registry (F.4): descriptors in Muster's signed package, keyed by program and
  image id, cross-checked against the chain's deployment header. It is not blocked on an on-chain
  registry, and it reads one if the LP lands.
- Decode-before-sign for arbitrary targets (U.6), with an explicit warning and a second
  confirmation for an unregistered one.
- The selective-disclosure tiers (F.10): a viewing key for a narrow audience, the self-verifying
  audit export for a wide one, and re-disclosure for ongoing assurance.
- A multisig view in the mini-app: the proposal list beside the room, queue and ETA, limits, and
  an error-message pass (U.2, U.7).
- Docs: the per-action public/private table (U.5), the cross-layer correlations (Privacy 3), the
  README (S.8), designs (S.11), and the requirement→test map (S.7).
- **Dogfood pilot:** a real group runs a small treasury on testnet: a Logos community wallet, or a
  circle from Jarrad's Logos-world work (exo-267).

### M5: audit (6–8 weeks calendar, external)

- Scope: the program, the approval-verification path, config change and time lock, spending
  limits (S.13).
- First, a review by the R&D Program team. Then a tier-1 firm; Franck books it. Lead times are
  long, so the booking should start now, against the M3 freeze.
- A fix round, then the report is published with the code.

### M6: the full `chat_module` binding

- The room behind `ConversationCrypto` moves onto `chat_module` once M3 shows parity. Proposals and
  approvals then travel there too.

### Tentative

- **T1: the L1 multisig in Muster.** A driver family for the Blockchain team's L1 multisig, once
  their design is fixed (likely programmable UTXOs, 0.5). It would decode the transaction on the
  card, collect approvals in the room, and submit through `logos_blockchain_module`. Also: the integrator signature-scheme matrix, completed
  for BitGo, Finoa, Copper and Anchorage (§4.3).
- **T2: onboarding across L1 and LEZ** (action items from 2026-11-11):
  - PoW rewards moving to a LEZ account automatically once a threshold is reached: keep the first
    reward on L1 for gas, then send each later one straight to LEZ;
  - a note on where bridging to a zone account ends and cross-zone messaging begins;
  - why bridge finalization is reported as ~8 hours.
- **T3: personal user mapping across zones.** Recorded, not prioritised.

## 4. The L1 multisig and integrators

Sources:
- [marclawclaw/research-mpc-custody](https://github.com/marclawclaw/research-mpc-custody) (MC),
  2026-11-08 to 11-10. It was checked against `logos-blockchain` @ `ce15ec1`, with the PoCs
  running inside the ledger crate.
- [research-multisig-sovereign](https://github.com/marclawclaw/research-multisig-sovereign) (MS),
  a survey written for RFP-005.

What follows restates them; where a line is our inference, it says so.

### 4.1 The L1 has its own key schemes

- There are two key types on Bedrock: **Ed25519** and **ZkSign**. ZkSign is a Groth16 proof that
  the prover knows the secrets behind the note keys. There is **no secp256k1** (MC
  `patterns/bedrock-key-types.md`).
- ZkSign's 32-key form is aggregation, not a threshold: one prover needs every key.
- The ledger's real K-of-N is the **channel**. `ChannelConfig`, `ChannelTransfer` and
  `ChannelWithdraw` take a proof of exactly k Ed25519 signatures from the channel's accredited
  keys. A config change must name the current config as its parent and be signed by the current
  key set.

### 4.2 The L1 multisig's mechanism

Removed in the 2026-11-20 revision: the Blockchain team defines it. The research above
(channels, FROST and co-proving on Bedrock) stays in the sources for reference.

### 4.3 What integrators' signers can produce

MC `metrics/signer-compat-matrix.md`:

| Vendor | Raw signing schemes |
|---|---|
| Fireblocks | EdDSA Ed25519, ECDSA secp256k1 |
| Fordefi (Paxos) | EdDSA Ed25519, ECDSA secp256k1, ECDSA Stark; signs blind |
| Dfns | EdDSA, ECDSA, Schnorr |

BitGo, Finoa (and its MPC provider), Copper and Anchorage are not covered yet; 0xGunner's deal
reviews this week can fill them in. No vendor output was tested against Bedrock. No vendor can
produce a ZkSign, so a custodian can hold channel keys but not plain notes, and cannot pay fees.

**The consequence for LEZ (our inference).**
- `lez-msig` approvals are BIP-340 Schnorr on secp256k1 (decision D3: the cheapest to verify in
  the zkVM, about 0.28M cycles with RISC Zero's accelerated k256), and so are LEZ public-account
  witnesses.
- Fireblocks and Fordefi cannot produce BIP-340.
- So a custodian can be neither a `lez-msig` member nor the single key of a LEZ account, unless:
  - the program also accepts **Ed25519** approvals. D3 rejected Ed25519 on cost (several million
    cycles unaccelerated on v0.3), but a mixed member set, where each member declares a scheme,
    keeps BIP-340 cheap for everyone else;
  - or LEZ accounts accept another witness scheme, which is the LEZ team's decision;
  - or the vendor adds BIP-340.

M2 adds Ed25519 member keys to the program, with the cost per approval measured, if Q6 confirms
that integrators need it. That is the change that makes "the program alone" usable by the
custodians named so far.

**The private posture and custodians.**
- A private `lez-msig` needs every member to hold the group secret (to prove), and an MPC
  custodian holds no such thing. So integrators will use the public posture, or be a member whose
  approvals another member's client proves.
- MS notes that a bare LEZ shared private account makes spending effectively 1-of-N, because every
  member holds the spending key. `lez-msig` closes exactly that gap: the program, not the key, is
  the gate (design §2).

## 5. Risks and dependencies

- **LEZ 0.4 is still moving.** rc3 was tagged 2026-11-11. The adapter split keeps a port to one
  thin layer, but M3's dates follow the 0.4 testnet's.
- **Proving on consumer hardware.** 15 s per approval is a 64-core figure. Laptop numbers in M1
  decide how the UI presents a 5–10 minute background job.
- **Fees on private transactions.** 0.4 shipped them (LEZ PR #985). Each private execution pays in
  the proof, from a private account with an authorization key, and the multisig's own account
  cannot pay. D17 proposes a group fee account; the alternative is the executor's own account,
  presented under a one-time alias.
- **Funding test networks.** The devnet funder account is made; it needs devnet LEZ (Q2). After
  that, testers fund from it.
- **`chat_module` removal (PR #357)** comes with limits:
  - a member cannot remove themself;
  - every member is an admin (the ASTRO security level);
  - it needs real-world testing.

  The room id on the wire and the central key-package service still need checking against
  Privacy-2.
- **Audit lead time.** This is the long pole; book it early.
- **One engineer.** EcoDev and QA review are how quality gets a second pair of eyes; the acceptance
  scripts are written so they can run them without me.
- **The published `lez-multisig`** has an unchecked-seeds bug (exo-325). Its quorum may move
  another multisig's vault. `lez-msig` re-derives its account in the plan and is not affected.
  The bug should go upstream regardless.

## 6. Open questions

1. **The L1 boundary.** Muster coordinates and the Blockchain team builds the mechanism; is that
   the agreed split? Who is Muster's contact there (0xGunner)?
2. **Devnet funds: answered.** The funder was funded and the program is deployed. More will be
   needed for Muster's room runs there.
   M1 targets the 0.4.0-rc3 devnet. Its funder account is
   `Public/A7D1JP1LZv9WnCuSZ5y89by5BvgbWJ7m4gUPzVM7KWDZ`, public key `ec559533fa2159ddc87e6b3486cfe3b72c18bc142ce1f509a79ccd73629d63db`; on 0.4 a
   fresh account is funded by its key. Who can send it devnet LEZ (James's prog-tui, or the L1
   bridge)?
3. **D17:** a group fee account derived from the group secret, or the executor's own private
   account? Both work on 0.4. The first keeps every member's account off chain; the second needs
   no shared balance.
4. **U.4:** is a SPEL IDL still required now that SPEL is thinning under 0.4?
5. **Audit:** which firm, budget and slot? And who besides Corey (the "other CC") reviews code?
6. **Integrators:** which schemes can BitGo and Finoa's MPC provider sign? Fireblocks and Fordefi
   offer Ed25519 and ECDSA secp256k1, but not BIP-340, which LEZ accounts and `lez-msig` approvals
   use (§4.3). Should the program accept Ed25519 members (M2)? And should the LEZ team consider a
   second account witness scheme?
7. **Rotation (D19):** does the zone team see any problem with rotating in the program on
   removal, as James's multisig does? (James is reviewing it with them.)
