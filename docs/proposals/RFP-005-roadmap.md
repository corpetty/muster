# RFP-005: progress against the accepted proposal

*Updated 2026-11-27. Owner: Corey Petty. Epic exo-0d3; this document is exo-0d3.19.*

**The reference is the accepted proposal,** [logos-co/rfp#299](https://github.com/logos-co/rfp/issues/299)
(accepted 2026-11-26; copied in [`RFP-005-lez-msig.md`](RFP-005-lez-msig.md)). It fixes the scope
and the five milestones, and **its Progress section is the canonical record of progress**. This
document is the engineering detail behind that section: what has been built, with its evidence,
and what is left, each with an issue under exo-0d3. When something lands, update both: the Progress
section on #299 in brief, this document in full.

Design and decision log (D1–D19): [`docs/design/lez-msig.md`](../design/lez-msig.md). Signing
spec: [`docs/design/lez-msig-signing.md`](../design/lez-msig-signing.md). Benchmarks:
[`programs/lez-msig/BENCHMARKS.md`](../../programs/lez-msig/BENCHMARKS.md). Reports to the module
teams: [`docs/upstream/`](../upstream/).

**How a milestone is signed off.** Each ends with:
- an acceptance script IFT-QA can run;
- a dogfood journey that a dedicated EcoDev engineer does by hand.

The R&D Program team reviews the program before the external audit.

## At a glance

| Milestone | Built | Left | Issues |
|---|---|---|---|
| M1 The multisig on LEZ 0.4 | Most of it: both postures on the 0.4 devnet with real proving, from Muster's UI; a private Call from the room; the fee balance; private by default; windows to the minute; rotation on removal in the program (D19) | D19 from the room, and deploying its program; a laptop benchmark; the dogfood journey | exo-3dc, exo-0d3.15, exo-d4b, exo-30b |
| M2 The program stands alone | The signing spec; key-free public-posture operations in the module and CLI | The full module API for both postures, a CLI over `logoscore`, the integration guide, Ed25519 members if needed | exo-dbd3, exo-c3b, exo-0d3.20 |
| M3 Decode, disclose, document | Decode-before-sign for the multisig's own actions; the guarantees page (U.5, Privacy 3, S.7) | The registry and arbitrary targets, the disclosure tiers, the mini-app view, the README and designs, a pilot | exo-ac1, exo-4cd4, exo-93b, exo-421c |
| M4 The chat binding and the IDL | Deliberation in a `chat_module` group that follows the members; the IDL through SPEL; CI on a 0.4 zone | The full binding | exo-13f |
| M5 Audit | — | Review, audit, fixes, report | exo-a80 |

Released: [muster-v0.4.0](https://github.com/corpetty/muster/releases/tag/muster-v0.4.0)
(2026-11-23) carries both postures on LEZ 0.4 and both provers. `lez_msig_module` 0.1.1 is the
LEZ v0.3 prover and `lez_msig_v04_module` 0.2.0 the v0.4 one; Muster calls the one its zone
needs. [muster-v0.5.0](https://github.com/corpetty/muster/releases/tag/muster-v0.5.0) (2026-11-24)
is the security release that followed an outside review of 0.4.0.

## M1: the multisig on LEZ 0.4

**Built.**
- The actor adapter over the same `msig_core`, in its own workspace (`programs/lez-msig/lez04`, PR #387).
- Deployed immutable on the 0.4.0-rc3 devnet at
  `2tTh5nUpBxtTAoQBCQbzmG32JGapm2KaEpH9oxktGanG`. On it:
  - **Public posture:** create on a fresh PDA, a refusal below threshold, a 2-of-3 payment.
    Muster's own room flow passed 7/7.
  - **Private posture, real proving:** fee-account top-up, Create, deposit and a 2-of-3 payment.
    Each proved in 104 s, 257 s, 233 s and 292 s, and paid a fee of about 5.7M.
  - **Through Muster's UI:** two runners opened a private 2-of-2, topped it up, created and funded
    it, approved on the card and settled, in 925 s end to end.
- **D17, decided and built.** Every private transaction pays its fee inside its proof, from a
  group fee account derived from the group secret and witnessed `FeeOnly`. Members top it up from
  a public account, and the top-up pays its own fee out of the credit.
- **D18, decided and built.** The program is proved undisclosed, so a transaction names no program.
- **Private payees** (exo-ea3) and **deposits from outside the group** (exo-05f).
  - A payment to a private payee is sealed to its `Recipient` and claimed by it alone.
  - Anyone can pay the vault's address from a public account, and the next transaction collects
    up to four deposits.
  - Both ran on LEE's 0.4 state and on a local 0.4 zone (`lez_msig_private_e2e`, `live_exec04`).
- **A private Call from the room** (exo-0db). A member proposes a Call (the program, its rows, the
  instruction) to a private multisig, members approve it on its card, and the prover proves it over
  the vault's note, the seed authorizing the vault. Run from a room on a local 0.4 zone
  (`lez_msig_private_e2e` §12: the native program at the vault's own balance, paying a public payee).
  The room's accounts panel has a call composer for either posture, not yet seen on a display.
- **The fee account's balance** (exo-8ef). Each member reads it from the newest fee note the room
  carries, against what the next private transaction reserves at the zone's fee state, and the
  multisig's panel shows both beside "Top up the fee account", warning when it cannot pay the next
  one (`msig_gas_test` §4; `lez_msig_private_e2e` §12 reads it run dry after seven transactions on a
  50M top-up, and tops it up).
- **Per-step gas limits** (exo-50c). On 0.4 a refused transaction burns its whole declared limit.
- **Recovery** of a lost note by scanning the chain with the group's viewing keys.
- **The room follows the program's members** (#382), and **spending limits** run from the room (#383).
- **The 0.4 prover as a Logos module,** `lez_msig_v04_module`, beside the v0.3 one, in Muster's
  catalogue and AppImage.
- **P.1/P.2 on 0.4,** real proving on a 64-core EPYC:
  - a payment proves in about 182 s + 11.5 s per approval;
  - the transaction is 229–238 KB whatever M is;
  - peak memory is about 9.6 GB.

**Left.**
- **D19 from the room** (exo-3dc). The program side is built (#403, `docs/design/lez-msig.md`
  "D19 in detail"): the approval that removes a member, in one transaction, retires the vault,
  hands its configuration to a successor at a new PDA from a new group secret, and moves the
  balance there; a retired vault forwards late deposits; the fee account moves in the transaction
  before. Left:
  - Muster's Nim port of `Rotate` and `Sweep`, held to `v04-rotation.json`;
  - proposing a rotation (a fresh create key and group secret, sealed to the remaining members
    only), approving it (each approver re-derives the successor), and the prover's rotate and
    sweep modes;
  - after a rotation: sealing the successor's notes, moving the room's keys, re-keying the removed
    member out, and sweeping late deposits;
  - deploying the new program (`lez04/artifacts/msig-next.bin`) locally, then on the devnet, and a
    real-proving benchmark of the rotation.
- A private Queue's slack is shorter than its proof (exo-30b).
- A laptop-class benchmark (exo-0d3.15).
- **Acceptance:** the dogfood journey in Basecamp (exo-d4b). A 2-of-3 private multisig on the
  devnet is opened, funded and paid out; a member is added and one removed, the vault rotates,
  and the removed member loses the room.

## M2: the program stands alone

**Built.**
- The signing spec with test vectors (PR #384): what an approval signs, for integrators without Muster.
- Key-free public-posture operations in `lez_msig_module` and `msig_exec` (PR #385): state,
  propose, spend, check, prepare and send. The README documents the no-Muster journey, run
  against a real sequencer with every key outside the module.

**Left.**
- `lez_msig_module` as the full multisig module (U.1, exo-dbd3): create, propose, approve, reject,
  execute, configuration and limits, for both postures and both LEZ lines, with progress events.
- A CLI over `logoscore` (U.3) and a bring-your-own-transport guide (S.9, S.10), in exo-c3b.
- Ed25519 member keys beside BIP-340 (exo-0d3.20), if integrators confirm they need them.
  Fireblocks and Fordefi sign Ed25519 and ECDSA secp256k1, not BIP-340 (see "Integrators" below).
- **Acceptance:** the full journey from the CLI alone, with one approval produced outside Muster
  from the spec.

## M3: decode, disclose, document

**Built.** The card decodes the exact bytes each approval signs, for every action the multisig
itself takes: create, transfer, call, configuration, spend and a private payee.

**Left.**
- The target-program registry and decode-before-sign for any target (F.4, U.6; exo-ac1).
  - Descriptors ship in Muster's signed package, keyed by program and image id, and are
    cross-checked against the deployment header. No on-chain registry is needed.
  - An unregistered target shows its raw bytes, with a warning and a second confirmation.
- The selective-disclosure tiers (F.10, exo-4cd4).
- A multisig view in the mini-app and an error pass (U.2, U.7; exo-93b).
- Documentation: the README (S.8) and designs (S.11). Built (#402): the per-action public/private
  table (U.5), the cross-layer correlations (Privacy 3) and the requirement-to-test map (S.7), in
  [`lez-msig-guarantees.md`](../design/lez-msig-guarantees.md), whose §3 lists the requirements no
  test holds yet.
- The room metadata the guarantees page found: unpadded note bursts, and a transaction hash outside
  the seal (exo-421c).
- **Acceptance:** a dogfood pilot, a real group running a small treasury on testnet.

## M4: the chat-module binding and the IDL

**Built.**
- Each multisig's deliberation runs in a `chat_module` group whose membership follows the
  program's (PR #388). Removal was proven on the live fleet with a patched module exposing
  `remove_group_member`.
- **The IDL (U.4)** through SPEL's `refactor/lez-v0.4.x` (#405): `lez04/idl/lez_msig.json`, the
  types named in `lez04/spel.toml` so `msig_core` keeps no SPEL dependency, and checked in CI
  (`lez-msig-idl`). SPEL cannot describe the struct the guest decodes, so the IDL describes
  `Instruction`; the limits are in `docs/upstream/spel-field-report.md`.
- **CI on a LEZ v0.4 zone (S.5, S.6)** (#405): the `lez-msig-v04` job runs the v0.4 live tests and
  Muster's private end-to-end test.

**Left.**
- The full binding behind `ConversationCrypto` (S.2, exo-13f). Proposals and approvals move there
  once `chat_module` reaches parity:
  - forward secrecy on removal;
  - a store node that cannot read membership;
  - an exportable proof.

## M5: audit

exo-a80. First a review by the R&D Program team, then a tier-1 audit of:
- the program;
- approval verification;
- configuration change and the time lock;
- spending limits;
- rotation on removal.

Then a fix round, and the report is published with the code. Book it early: the code freeze
follows M1 and M2.

## Requirement by requirement

✅ done · 🟡 partial · ⬜ not started · ↪ deliberate deviation. Milestone in brackets.

| Req | | Where it stands |
|---|---|---|
| F.1 M-of-N, members, threshold, action set | ✅ | `msig_core`, `rules.rs` |
| F.2 lifecycle, expiry, off-chain collection | ✅ | approvals collected in the room, verified in the program |
| F.3 arbitrary program calls | ✅ | `Call`; a private Call from the room ran on a local 0.4 zone (exo-0db) |
| F.4 target registry | ⬜ | exo-ac1 (M3) |
| F.5 configuration through the quorum | ✅ | the room follows the program's members (#382) |
| F.6 role separation | ✅ | PROPOSE / APPROVE / EXECUTE |
| F.7 time lock | ✅ | validity windows; a pessimistic ETA |
| F.8 spending limits | ✅ | from the room (#383) |
| F.9 E2EE room per multisig | ✅↪ | Muster's room; the chat module carries deliberation (S.2) |
| F.10 private default, public posture, disclosure | 🟡 | both postures ✅; private by default ✅ (#407); disclosure tiers exo-4cd4 (M3) |
| U.1 a module other modules call | 🟡 | prover and public-posture operations ✅; the full API exo-dbd3 (M2) |
| U.2 QML mini-app | 🟡 | Muster in Basecamp; a multisig view exo-93b (M3) |
| U.3 CLI on the headless core | 🟡 | `msig_exec`; over `logoscore` exo-c3b (M2) |
| U.4 IDL | ✅ | through SPEL's v0.4.x branch, types named in `spel.toml`, checked in CI (#405) |
| U.5 per-action public/private | ✅ | `lez-msig-guarantees.md` §1 (#402) |
| U.6 decode before signing | 🟡 | own actions ✅; any target exo-ac1 (M3) |
| U.7 actionable errors | 🟡 | refusal codes ✅; UI pass exo-93b (M3) |
| R.1 distinct current members, exactly this action, no replay | ✅ | `rules.rs`, `v03_state.rs`, `v04_state.rs` |
| R.2 configuration change voids old approvals | ✅ | the epoch; the cutoff is the queue |
| P.1 cost, size, proving time | 🟡 | 64-core, v0.3 and v0.4 ✅; laptop exo-0d3.15 (M1) |
| P.2 cost against M, M ≥ 5 viable | ✅ | about 11.5 s per approval on 0.4 |
| S.1 LEZ, private accounts | ✅ | |
| S.2 the room on `chat_module` | ↪ | deliberation ✅ (#388); full binding exo-13f (M4) |
| S.3/S.4 testnet 0.4, deployed | ✅ | the 0.4.0-rc3 devnet, both postures |
| S.5/S.6 e2e in CI, green | ✅ | local v0.3 and v0.4 zones in CI (#405) |
| S.7 a test per hard requirement | 🟡 | the map ✅ (`lez-msig-guarantees.md` §3); some requirements still have no test |
| S.8–S.10 README, API, CLI docs | 🟡 | exo-05d (M3), exo-c3b (M2) |
| S.11 designs | 🟡 | exo-05d (M3) |
| S.12 own catalogue | ✅ | both provers in Muster's catalogue |
| S.13 audit | ⬜ | exo-a80 (M5) |
| S.14 decision log | ✅ | design §9, D1–D19 |
| Privacy 1–3 | 🟡 | documented (`lez-msig-guarantees.md` §1–2); windows to the minute (#407); room metadata exo-421c |
| Soft: weighted approvals | ✅ | |
| Soft: proof of holding, mixed postures | ⬜ | not in the proposal |

## Integrators

Integrators use different layers: BitGo uses a chain's own multisig program, while custodians
(Fireblocks, Copper, Anchorage) put one key on chain and run approvals in their own MPC. The
proposal's three layers, the program, the signing seam and the room, serve each.

The signers they run produce these schemes, per
[research-mpc-custody](https://github.com/marclawclaw/research-mpc-custody)
`metrics/signer-compat-matrix.md`:

| Vendor | Raw signing schemes |
|---|---|
| Fireblocks | EdDSA Ed25519, ECDSA secp256k1 |
| Fordefi (Paxos) | EdDSA Ed25519, ECDSA secp256k1, ECDSA Stark; signs blind |
| Dfns | EdDSA, ECDSA, Schnorr |

`lez-msig` approvals and LEZ public-account witnesses are BIP-340. That choice is D3, made on proving
cost. So Fireblocks and Fordefi can be neither a member nor a LEZ account's single key, unless
the program also accepts Ed25519 members (exo-0d3.20, in M2 if confirmed) or LEZ accounts accept
another witness scheme, which is the LEZ team's decision.

A private multisig needs every member to hold the group secret, which an MPC custodian does not.
So custodians use the public posture, or join as a member whose approvals another member's client
proves.

## Outside the proposal

- **The Logos blockchain (L1) multisig** is the Blockchain team's to design, likely on the
  programmable UTXOs of 0.5. Muster's part would be a driver family for it, which would collect
  approvals in the room and decode the transaction on the card. Tracked as exo-0d3.21, and it
  starts once their design is fixed.
- **Onboarding across L1 and LEZ** (exo-0d3.22, exo-0d3.23):
  - moving PoW rewards to a LEZ account automatically;
  - where bridging ends and cross-zone messaging begins.
- **LEZ Wallet accounts approving a lez-msig** (exo-0d3.18). This waits on
  `sign_message` upstream (logos-execution-zone-module#73).

## Risks

- **LEZ 0.4 is a release candidate.** The core/adapter split keeps a runtime port to one thin
  adapter, and both lines' provers ship side by side.
- **Proving on consumer hardware.** Every figure so far is 64-core. The laptop benchmark decides
  how the UI presents a proof of several minutes.
- **A refused 0.4 transaction burns its whole gas limit,** and nothing estimates one. Every step
  declares a limit fitted to what it meters (exo-50c), and the LEZ team has the ask
  (`docs/upstream/lez-v04-field-report.md`).
- **The chat module's removal** is not in a release yet, and needs real-world testing. Its key
  service and the room id on the wire still have to be checked against Privacy-2.
- **Building the provers needs risc0's recursion circuit.** risc0's own URL has answered 403 since
  2026-11-23. Muster's flakes and CI fall back to the Logos nix cache and a copy on muster-v0.4.0
  (exo-ba5), and the LEZ team has the ask.
- **Audit lead time** is the long pole.
- **One engineer.** EcoDev, IFT-QA and the R&D review are the second pair of eyes. The acceptance
  scripts are written so they can run them alone.
- **The published `lez-multisig`** passes seeds unchecked (exo-325): one quorum may move another
  multisig's vault. `lez-msig` re-derives its account and is not affected; the bug goes upstream.

## Decisions still open

Each was named as open in the accepted proposal:
1. **Payouts,** to be agreed with Logos: the author is a core contributor.
2. **The audit firm and slot** (M5).
3. **Ed25519 members** (M2): do integrators need them? That is for the integrators to answer.

**Answered since:** the IDL route (M4). An IDL is still required, through SPEL's v0.4.x branch
(r4bbit, 2026-11-26); lez-msig names its types in `spel.toml`.
