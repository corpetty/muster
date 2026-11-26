# RFP-005 proposal: lez-msig (accepted)

**This is the reference** for the lez-msig work's scope, milestones and state. It is the proposal
filed as [logos-co/rfp#299](https://github.com/logos-co/rfp/issues/299) on 2026-11-25 and
**accepted** on 2026-11-26. It is copied verbatim below, with the email addresses left in the
issue. The form's RFP ID dropdown had no RFP-005 option, so it reads RFP-017; the RFP team moved
the issue to RFP-005.

Progress against these milestones is tracked in [`RFP-005-roadmap.md`](RFP-005-roadmap.md). The
design and decision log is [`docs/design/lez-msig.md`](../design/lez-msig.md). If this proposal
and another document disagree on scope, this one wins; on what has been built since 2026-11-25,
the roadmap does.

---

## RFP ID

RFP-017 — Privacy-Preserving Token Vesting

## Your Project Name

lez-msig: a private-by-default M-of-N multisig on LEZ, run from an encrypted Muster room (RFP-005)

## Team or Organization Name

Petty Services, Inc

## Primary Contact

@corpetty (X, Telegram, GitHub); email addresses as in the filed issue

## Team Members

Member 1
Name or pseudonym: Corey Petty
Social links: https://github.com/corpetty · https://x.com/corpetty · Telegram @corpetty
Role: sole engineer: design, implementation and maintenance of the program, the module and Muster
Status: full-time (tech evangelist)

## Project Summary

This proposal is for **RFP-005 (Multisig and Coordination)**. The form lists no RFP-005 option, so another RFP was picked as a placeholder, as we were told to do.

A multisig has two halves:
- the program that enforces M-of-N;
- the place where members agree on what to sign.

Most bids spend their words on the first half, but production multisigs leak through the second. Safe leaks through a relay that sees everything, Squads through public on-chain votes, and Bitcoin through whatever chat the signers happen to use. The Bybit and WazirX losses happened in that second half: what the signers were shown was not what they signed.

We are not proposing a design. We are proposing to finish one that already runs on LEZ 0.4. It shipped in [Muster 0.4.0](https://github.com/corpetty/muster/releases/tag/muster-v0.4.0) on 2026-11-23. The next day, [Muster 0.5.0](https://github.com/corpetty/muster/releases/tag/muster-v0.5.0) fixed every finding of an outside security review of 0.4.0.

- **The program is written, deployed and measured** (`programs/lez-msig/`).
  - One program serves both postures: a public PDA, or a group-owned private PDA, the default.
  - Approvals are collected off-chain and verified inside the program at execution.
  - It is deployed immutable on the LEZ 0.4.0-rc3 devnet (`2tTh5nUpBxtTAoQBCQbzmG32JGapm2KaEpH9oxktGanG`). Both postures passed there with real proving.
  - In the private posture, top-up, Create, deposit and a 2-of-3 payment were each one privacy-preserving transaction. Each paid its fee inside its proof and named no program.
- **The coordination layer is shipping software.** Muster is a released Logos client, installable in Basecamp from its own catalogue. A Muster room is an encrypted, signed, epoch-keyed log, and it re-keys forward when membership changes.
  - A multisig is opened from a room: a ceremony binds each member's approval key to their room identity.
  - It is funded, proposed, approved and executed from the room. The card decodes the exact bytes each approval signs.
  - This was run through two real Muster clients against the devnet with real proofs, and the private 2-of-2 was settled in 925 s end to end.
- **The program also stands alone.** Integrators who bring their own transport and signers get:
  - a written signing spec with test vectors (`docs/design/lez-msig-signing.md`);
  - a key-free Logos module and CLI (`lez_msig_module`, `msig_exec`).
- **The hardest unpriced item is priced.** RFP §Risks names approval-verification cost. On LEZ 0.4, with real proving on a 64-core machine:
  - a private payment proves in about 182 s + 11.5 s per approval;
  - the transaction is 229–238 KB whatever M is.

  M ≥ 5 is comfortably viable (`programs/lez-msig/BENCHMARKS.md`).

What remains turns a working core into an audited product:
- rotation on removal;
- the target-program registry and decode-before-sign for any target;
- selective disclosure;
- the mini-app view and documentation;
- the full chat-module binding;
- an audit.

Why it matters: a group on Logos should be able to hold funds together without telling the chain, a relay or a chat server who its members are, who approved what, or what they discussed. Every member should see exactly what they are signing.

## Technical Approach

**Three layers, each usable without the others.** Integrators want different subsets: BitGo uses a chain's own multisig program, custodians bring their own MPC, and Logos treasuries want the whole stack. So the deliverable has documented seams:

| Layer | What it is |
|---|---|
| 1. The program | `lez-msig`: M-of-N enforced by the LEZ program, which verifies BIP-340 approvals at execution, however they were collected. |
| 2. The signing seam | A spec of exactly what an approval signs, with vectors. A signature from an HSM, an MPC cluster or a keystore counts the same. |
| 3. The coordination room | Muster: an encrypted room where members deliberate. The card decodes the exact bytes before signing, and approvals are collected off-chain. |

**Architecture.**
- The rules live in a core crate with no LEZ dependency (`msig_core`), as two pure functions.
- Thin adapters map the core onto a runtime: v0.3's `run_program(plan, apply)`, and v0.4's transactional actors in their own workspace.
- Posture is placement, not a fork: the same audited program runs over a public PDA or a group-owned private PDA.

**Approvals (F.1, F.2, R.1).**
- Each member holds a per-multisig BIP-340 approval key, derived in their own keystore and never exported.
- The program verifies, at execution, distinct current members holding the APPROVE role, weighted, over exactly this proposal. The proposer's own signature is required.
- The signed digest is a BIP-340 tagged hash that commits to:
  - the zone;
  - the multisig's account;
  - the configuration epoch;
  - a nonce;
  - the action;
  - an expiry.

  A signature is worthless anywhere else.
- Replay: a 256-nonce window, used in any order and only once.
- RISC Zero's accelerated k256, patched into our guest only, verifies a BIP-340 signature 2.9× faster than stock.

**Configuration and R.2 (F.5).**
- A configuration change is a proposal through the same quorum and time lock.
- Executing one bumps the epoch, so every approval gathered under the old configuration stops counting at once.
- The cutoff is the queue: an action already queued survives a change, and the current quorum can cancel it immediately, since cancels are never time-locked.
- The room follows the program: it folds executed configuration changes, re-keys a removed member out, and gives an added member the group secret.

**Roles (F.6).**
- **PROPOSE:** the program refuses an action its proposer did not sign.
- **APPROVE:** only APPROVE signatures count, by weight.
- **EXECUTE:** with open execution off, an EXECUTE member must sign the execution.

**Time lock, expiry, spending limits (F.7, F.8).**
- A program reads no clock, so every time is a claim the plan binds with a sequencer-enforced validity window.
- An ETA is pessimistic, never early.
- Spending limits let k of a limit's own signers spend up to an amount per period: the one declared bypass of the quorum. Adding one and spending under it both run from the room.

**Arbitrary calls (F.3).**
- A `Call` action chains any program, granted exactly the multisig's own PDA seed.
- The plan re-derives the multisig's account from its placement and refuses any other row, so one quorum cannot move another multisig's vault.
- The published `lez-multisig` passes seeds unchecked, which is that bug; we will report it upstream.

**The private posture on LEZ 0.4 (F.10, Privacy).**
- The state and vault are one private PDA, whose keys come from a group master secret sealed to each member inside the room.
- The secret lets a member operate the multisig but not spend: the program is the only gate.
- **Fees (D17).** On 0.4 a private transaction pays its fee inside its proof, and a PDA cannot pay. So the group has a fee account derived from the same secret, witnessed `FeeOnly`. Any member tops it up from their own account in one proof that pays its own fee out of the credit, so a group needs no funds to start.
- **No program named (D18).** The program is deployed immutable and proved undisclosed, so observers cannot tell which program ran.
- **Private payees.** A payment to one is sealed to its `Recipient` and claimed by it alone; its address appears nowhere in the transaction.
- **Deposits from anyone.** The vault's Create registers a recovery binding, so anyone can pay its address from a public account. The group collects deposits in its next transaction, at most four at a time.
- A note lost from the room is recovered by scanning the chain with the group's viewing keys.
- What each observer sees, item by item, is §7 of `docs/design/lez-msig.md`, including the correlations that remain:
  - room traffic timing against executions;
  - public validity-window bounds;
  - a public payee's credit.

**Removal and revocation (D19).** A shared secret cannot be revoked, so removal rotates the vault inside the program. The approval that removes a member also, in the same transaction:
- retires the vault;
- hands its configuration to a successor at a new PDA from a new group secret;
- moves the whole balance there.

This is the pattern James Zaki's 0.4 multisig uses. A removed member can never spend, and after rotation cannot read the new vault either.

**Decode-before-sign and the registry (F.4, U.6).**
- The room's effect is the proposal's exact borsh bytes, and the card decodes those bytes, so what a member sees is what their approval signs. This is done for the multisig's own actions.
- Arbitrary targets are decoded through program descriptors:
  - shipped in Muster's signed package;
  - keyed by program account and image id;
  - cross-checked against the chain's deployment header.

  This needs no on-chain registry, and it reads one if that lands.
- An unregistered target shows its raw program id, rows and bytes with a warning, and approving it takes a second confirmation.

**Selective disclosure.**
- A narrow audience gets the PDA's viewing key.
- A wide audience gets Muster's self-verifying signature-audit export.
- Ongoing assurance comes from re-disclosure checked against the chain's commitment set.

**The coordination room (F.9) and the chat module (S.2).**
- In the creation ceremony, each member's approval key is bound to their room identity by two signatures. The binding exists only inside the room.
- Withholding, reordering, replaying or forking the room cannot produce an invalid execution: the program re-verifies everything. What remains at risk is liveness.
- Each multisig's discussion already runs in a `chat_module` group that follows its members. Removal was proven on the live fleet with a patched module exposing `remove_group_member`.
- Proposals and approvals stay on Muster's room, behind a `ConversationCrypto` seam, until the chat module reaches parity: forward secrecy on removal, a store node that cannot read membership, and an exportable proof. The full binding is a milestone below.

**Integrators' signers.** Fireblocks and Fordefi sign Ed25519 and ECDSA secp256k1, not BIP-340. If integrators confirm they need it, we add Ed25519 member keys alongside BIP-340, each member declaring a scheme, with the cost per approval measured.

**Anticipated challenges.**
- **LEZ 0.4 is still moving** (rc3). The core/adapter split keeps a runtime port to one thin layer.
- **Proving on consumer hardware.** Our figures are from a 64-core machine. A laptop-class benchmark decides how the UI presents a background job of several minutes.
- **On 0.4 a refused public transaction burns its whole declared gas limit,** and there is no way to estimate one. Every Muster send therefore declares a limit fitted to what its step meters.
- **The chat module's removal and its key-package service** still need real-world testing against Privacy-2.
- **Audit lead time** is the long pole.

## Milestones, Payout and Timeline

Status as of 2026-11-25. Much of Milestones 1, 2 and 4 is built, merged and released in Muster 0.4.0. What is left in each is listed, and a milestone is paid when it is accepted.

**Milestone 1 — The multisig on LEZ 0.4**
Payout: To be agreed with Logos (core contributor; the compensation arrangement is pending)
Duration: 4 weeks
Deliverables:
- Done:
  - the actor adapter;
  - the program deployed immutable on the 0.4.0-rc3 devnet;
  - the public and private postures there with real proving;
  - D17 (fees from a group fee account) and D18 (proved undisclosed);
  - private payees, deposits from outside the group, and recovery by scan;
  - per-step gas limits;
  - the room following the program's members;
  - spending limits from the room;
  - the 0.4 prover as a Logos module (`lez_msig_v04_module`), in Muster's catalogue;
  - the P.1/P.2 benchmarks on 0.4.
- Left:
  - in-program rotation on removal (D19), with a sweep for deposits that reach a retired vault;
  - the private posture's Call from the room;
  - the fee account's balance on the card;
  - a laptop-class benchmark;
  - the dogfood journey in Basecamp: a 2-of-3 private multisig opened, funded, paid out, a member added and one removed, with the vault rotating.

**Milestone 2 — The program stands alone**
Payout: To be agreed with Logos (core contributor; the compensation arrangement is pending)
Duration: 3 weeks
Deliverables:
- Done:
  - the signing spec with vectors;
  - the key-free public-posture operations in the module and `msig_exec`.
- Left:
  - `lez_msig_module` becomes the full multisig module (U.1): create, propose, approve, reject, execute, configuration and limits, for both postures and both LEZ lines, with progress events while a proof runs;
  - a CLI over `logoscore` (U.3);
  - a "bring your own transport" integration guide (S.9, S.10);
  - Ed25519 member keys, if integrators confirm they need them.
- Acceptance: the full journey from the CLI alone, with one approval produced outside Muster from the spec.

**Milestone 3 — Decode, disclose, document**
Payout: To be agreed with Logos (core contributor; the compensation arrangement is pending)
Duration: 3 weeks
Deliverables:
- the target-program registry (F.4) and decode-before-sign for arbitrary targets (U.6);
- the three selective-disclosure tiers (F.10);
- a multisig view in the mini-app: the proposal list beside the room, queue and ETA, limits, and an error-message pass (U.2, U.7);
- documentation:
  - the per-action public/private table (U.5);
  - the cross-layer correlations (Privacy 3);
  - the README (S.8);
  - designs (S.11);
  - the requirement-to-test map (S.7);
- a dogfood pilot: a real group runs a small treasury on testnet.

**Milestone 4 — The chat-module binding and the IDL**
Payout: To be agreed with Logos (core contributor; the compensation arrangement is pending)
Duration: 3 weeks
Deliverables:
- Done: each multisig's deliberation runs in a `chat_module` group that follows its members, with removal proven on the live fleet.
- Left:
  - the room behind `ConversationCrypto` moves onto `chat_module` once it reaches parity, so proposals and approvals travel there too (S.2);
  - member removal contributed upstream if it has not shipped;
  - the IDL (U.4), through SPEL or its 0.4 successor;
  - CI against a standalone 0.4 sequencer, green on the default branch (S.5, S.6).

**Milestone 5 — Audit**
Payout: To be agreed with Logos (core contributor; the compensation arrangement is pending); it includes the audit firm's quote
Duration: 6–8 weeks (calendar, external)
Deliverables:
- a review by the R&D Program team, then a tier-1 audit (the firm to be chosen with Logos) of:
  - the program;
  - the approval-verification path;
  - configuration change and the time lock;
  - spending limits;
  - rotation on removal (S.13);
- a fix round;
- the published report.

## Total Requested Budget (USD)

To be agreed with Logos (core contributor; the compensation arrangement is pending)

## Relevant Experience

- **Muster:** https://github.com/corpetty/muster, a released Logos client for multi-party transactions inside encrypted conversations. It is installable in Basecamp from its own catalogue. The latest release is [muster-v0.5.0](https://github.com/corpetty/muster/releases/tag/muster-v0.5.0), a security release: it fixes every finding of an outside review of 0.4.0, and every grant and message frame in a room is now signed (`docs/design/signed-room-wire.md`).
- **The work this proposal finishes**, merged and open for review:
  - corpetty/muster #382–#388, #390 and #391 (released in 0.4.0);
  - the program: `programs/lez-msig/` (v0.3) and `programs/lez-msig/lez04/` (v0.4);
  - the design and decision log D1–D19: `docs/design/lez-msig.md`;
  - the benchmarks: `programs/lez-msig/BENCHMARKS.md`.
- **The same client already coordinates other multisig families from its rooms:**
  - a Safe on Sepolia, from two Basecamp profiles;
  - Bitcoin multisig through PSBT;
  - the vote-locus LEZ multisig on the LEZ testnet;
  - FROST on Bitcoin and LEZ;
  - Monero multisig;
  - bill splits across EVM, Bitcoin, LEZ private and Monero.
- **Field reports to the Logos module teams**, from building this (`docs/upstream/`):
  - LEZ 0.4: costs, latency and ten findings with asks;
  - the chat module: removal, addresses and membership timing;
  - the module builder.

## Post-Delivery Plan

Corey Petty (Petty Services, Inc) maintains it after delivery.

The program, the module and the mini-app live in the Muster repository and catalogue, and are maintained with Muster. LEZ releases are tracked as they ship: the core/adapter split keeps a runtime port to one thin adapter, and both LEZ lines' provers ship side by side. Findings in modules we depend on go back to their teams as field reports.

## Permissions and Consent

- [X] I/We confirm Logos may contact me using the primary contact information provided above for follow-ups and next steps.
- [X] I/We consent to Logos using information from this proposal publicly such as blogs case studies social posts or analytical reporting. Redactions can be requested at any time.

## Program Requirements

- [X] I/We have read and agree to the Logos RFP Terms and Conditions and I understand that no Grant is awarded and no right to payment arises unless a Grant Agreement is executed.
- [X] I/We understand that RFP specifications are proposals rather than instructions, that Logos makes no representations as to their legal or regulatory treatment, and that we are responsible for assessing what we build, deploy or operate and for complying with the laws that apply to us.
- [X] I/We understand this project must be open-sourced under the MIT and Apache 2.0 Licenses unless explicitly approved otherwise.
- [X] I/We are prepared to deliver milestone-based outcomes.
