# RFP-005 roadmap: the multisig, the program and the room

*Draft, 2026-11-17. For Franck, the EcoDev engineer who will dogfood it, and IFT-QA. Owner:
Corey Petty. Tracked as exo-0d3 (epic) and exo-0d3.19 (this document); new items exo-0d3.20 (Ed25519 members), .21 (T1), .22 and .23 (T2).*

Muster takes RFP-005 ([the spec](https://github.com/logos-co/rfp/blob/master/RFPs/RFP-005-multisig-and-coordination.md))
under the usual RFP process. A dedicated EcoDev engineer drives each milestone: they announce it,
dogfood it, give feedback and sign it off. IFT-QA runs the acceptance scripts, the R&D Program team
reviews the program, and the program goes on the audit track. This document lists what is done,
what comes next, and the two scope changes agreed since 2026-11-11.

The program was the RFP's largest unknown, and it is already written and measured. The work left is
mostly productising it: the LEZ 0.4 port, a standalone module and CLI for integrators, the registry
and the documentation, and the audit.

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

The Blockchain team builds the L1 multisig (Ksr, 2026-11-16). From the 2026-11-11 call: prefer the
ledger's native K-of-N enforcement through channels and the zone protocol (sequencer signatures)
over FROST-style schemes. ZK notes cannot carry a multisig, and co-proving through MPC is
immature. The new private UTXOs bring some programmability to notes.

Muster's part is coordination: a driver family for the L1 multisig once its design settles, the
same room, the same decode-before-sign card. It is a **tentative milestone** (T1), sequenced after
the Blockchain team's design. §4 holds what the research found.

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
| F.4 proposal/target registry | ⬜ | designed (descriptors keyed by program + image id); M4 |
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
| S.2 the room on `chat_module` | ↪ | chat 0.3.0 has no member removal, so it cannot reconcile membership; binding seam ready (M6) |
| S.3/S.4 testnet 0.4, deployed there | ⬜ | LEZ `v0.4.0-rc3` is tagged (2026-11-11); M3 |
| S.5/S.6 e2e against a standalone sequencer in CI, green | ⬜ | the tests exist; no CI runs them (exo-1ec.2); M3 |
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
- **Not done:**
  - the devnet deployment: the devnet's address is not reachable from the build host;
  - real-proving runs from a room;
  - a laptop-class benchmark.

## 3. Milestones

Each milestone ends with an **acceptance script** IFT-QA can run, and a **dogfood journey** the
EcoDev engineer does by hand. Sign-off is on both. Week estimates assume one engineer (Corey),
starting 2026-11-23. Milestones 2 and 3 can overlap.

### M1: on a network people can reach (2 weeks, to ~2026-12-04)

- Deploy the program on the LEZ devnet (the 0.3.5-rc1 deployment Franck shared). Point Muster at
  it, and give the devnet a funder so testers don't wait on a faucet (`infra/lez/funder.sh`).
- Both postures run live with real proving (exo-0d3.15). This is the first real-proving run of the
  private posture from a room.
- The room's membership follows the program's on every config change: a removed member is evicted
  and the room re-keys forward (exo-0d3.13). Spending limits can be proposed from the room
  (exo-0d3.12).
- P.1/P.2 benchmarks are rerun on an idle machine and on a laptop-class one.
- **Dogfood:** install Muster from the catalogue in Basecamp. Two people open a 2-of-3 private
  multisig on the devnet, fund it, pay out, add a member, remove one, and watch the removed
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

### M3: LEZ 0.4 (3 weeks, from when the 0.4 devnet or testnet is up)

- The actor-model adapter over the same `msig_core` (exo-0d3.9), on LEZ `dev` / `v0.4.0-rc*`,
  plus Muster's own LEZ paths (the tx codec and the `lez_core` pin).
- The program deployed and tested on testnet 0.4 (S.3, S.4), with P.1/P.2 rerun there.
- The IDL (U.4): SPEL if it still makes sense under 0.4, otherwise James Zaki's successor tooling
  or one generated from the core types.
- CI: the e2e tests against a standalone sequencer, green on `main` (S.5, S.6, exo-1ec.2).
- **Code freeze for the audit at the end of M3.**

### M4: decode, disclose, document (3 weeks, to ~early February)

- The target-program registry (F.4). Decode-before-sign for arbitrary targets (U.6), with an
  explicit warning and a second confirmation for an unregistered one.
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

### M6: the `chat_module` binding (when chat ships member removal)

- The room behind `ConversationCrypto` moves onto `chat_module`, contributing removal upstream if
  needed. Until then S.2 stays a documented deviation: chat 0.3.0 cannot evict a member, sends the
  room id in the clear, and registers key packages with a central service.

### Tentative

- **T1: the L1 multisig in Muster.** A driver family for the Blockchain team's L1 multisig
  (likely a channel with native k-of-n Ed25519, §4.2):
  - the Ops decoded on the card before signing;
  - k signatures collected in the room;
  - submitted through `logos_blockchain_module`.

  It starts when their design is fixed. Also: the integrator signature-scheme matrix, completed
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

### 4.2 The channel as a treasury: what Muster would coordinate

This is MC's "treasury as a channel", the shape from the 2026-11-11 call.
- A channel is created by config alone, with no sequencing duty.
- Deposits arrive by `ChannelDeposit`, signed with the depositor's ZkSign.
- Payouts are a `ChannelTransfer` plus a `ChannelWithdraw` with k signatures.

On chain anyone can see the channel id, the key list, both thresholds, every config change, and
**which key indices signed each payout**. That is the transparent posture, which RFP-005's privacy
requirements do not cover.

Rough edges the research found:
- The ledger accepts a threshold above n, which locks payouts.
- It accepts a duplicate key.
- Fees need a small ZkSign fee note.
- Payers must use `ChannelDeposit`.
- Using channels as treasuries is "off-label": the accredited keys double as the sequencer
  rotation list.

The pieces MC lists as missing are a Muster driver almost exactly:
- an **Ops decoder**, so that approvers see more than a 32-byte hash;
- a **signer adapter**;
- a policy check before signing.

The node module already has the seams: `wallet_fund_tx` returns unsigned Ops, and
`submit_signed_transaction` sends them. So T1 is a driver family with a decode-before-sign card
over the Blockchain team's mechanism, and it can start as soon as they confirm the channel shape.
Muster's room would carry the k Ed25519 signatures exactly as it carries a Safe's or a PSBT's.
This is our inference, to confirm with them.

Two other shapes are in MC. Neither is recommended:
- one FROST-Ed25519 key with threshold 1, which hides who signed;
- co-proving a ZkSign with TACEO co-circom, which is n-of-n, semi-honest, unaudited and GPL-3.0.

Private UTXOs with programmable spend conditions postdate this research. If notes gain a K-of-N
predicate, it could replace the channel workaround. That is a question for the Blockchain team.

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
- **Fees on private transactions** (LEZ PR #949) would link the executor of a private multisig.
  We have to watch what 0.4 ships.
- **Funding test networks.** There is no faucet on v0.3 and RLN membership on `logos.test`.
  Every live run needs someone to fund an account. A devnet funder in M1 removes that for testers.
- **Audit lead time.** This is the long pole; book it early.
- **One engineer.** EcoDev and QA review are how quality gets a second pair of eyes; the acceptance
  scripts are written so they can run them without me.
- **The published `lez-multisig`** has an unchecked-seeds bug (exo-325). Its quorum may move
  another multisig's vault. `lez-msig` re-derives its account in the plan and is not affected.
  The bug should go upstream regardless.

## 6. Open questions

1. **The L1 boundary.** Muster coordinates and the Blockchain team builds the mechanism; is that
   the agreed split? Who is Muster's contact there (0xGunner)?
2. **Which network for M1:** the 0.3.5-rc1 devnet now, or wait for a 0.4 devnet? Can it have a
   funder account we hold?
3. **S.2:** is Muster's room an accepted deviation until `chat_module` has member removal?
4. **U.4:** is a SPEL IDL still required now that SPEL is thinning under 0.4?
5. **Audit:** which firm, budget and slot? And who besides Corey (the "other CC") reviews code?
6. **Integrators:** which schemes can BitGo and Finoa's MPC provider sign? Fireblocks and Fordefi
   offer Ed25519 and ECDSA secp256k1, but not BIP-340, which LEZ accounts and `lez-msig` approvals
   use (§4.3). Should the program accept Ed25519 members (M2)? And should the LEZ team consider a
   second account witness scheme?
7. **The L1 channel as a treasury:** does the Blockchain team bless that use (MC calls it
   off-label)? Will they fix the threshold-above-n and duplicate-key acceptance? Do private UTXOs
   give notes a k-of-n spend condition instead?
