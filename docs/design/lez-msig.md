# lez-msig: an M-of-N multisig on LEZ, private by default, run from a muster room

Status: **built and released** for LEZ v0.3 and v0.4 (muster-v0.4.0, 2026-11-23); updated
2026-11-26. Epic exo-0d3; RFP-005, `logos-co/rfp` `RFPs/RFP-005-multisig-and-coordination.md`.
Scope and milestones are the accepted proposal
([`docs/proposals/RFP-005-lez-msig.md`](../proposals/RFP-005-lez-msig.md), logos-co/rfp#299), and
progress against it is kept on the issue (its Progress section), with the engineering detail in [`RFP-005-roadmap.md`](../proposals/RFP-005-roadmap.md). This document is
the design and its decision log (§9).

It was first written on 2026-10-23 against LEZ v0.3.1 (`1a003bf`) and `dev` @ `7cba743a` (the
actor model, PR #935), and every LEZ fact in it was read in that source. The 0.4 port read
LEZ v0.4.0-rc3 (D13–D19, and `docs/labbook/lez-v04-port.md`).

This supersedes the vote-locus program (`lez.multisig-program`, `docs/design/lez-multisig-v03.md`)
for new multisigs. That program stays readable, but it is public by construction: every vote is
a public transaction naming its member.

## 1. The shape

- **One program, one account.** A multisig is ONE program-derived account (a PDA of the program
  and a seed from its create key). The program's shard of it holds the configuration and state;
  its native shard is the vault. Nothing is claimed and members need no setup.
- **Signatures, not seats.** Each member holds a per-multisig **approval key** (BIP-340,
  secp256k1), derived in their own keystore and never exported. Proposals and approvals never
  touch the chain: they are signed in the room. One transaction executes an action, carrying the
  proposal and its approvals, and the program verifies them **inside its own execution** (R.1).
  LEZ's PR #1001 manual lists this as the alternative to seats: seats cost 2k proofs per action,
  signatures one.
- **Posture is placement, not a program fork.** The same program runs over a **public** PDA (the
  public posture) or a **group-owned private PDA** (the private posture, the default). A private
  execution is one privacy-preserving transaction with no public signer and the program's image
  undisclosed. It is fee-exempt on v0.3; on v0.4 it pays its fee inside the proof, from the
  group's fee account (D17).
- **Rules in a core crate.** `msig_core` holds every rule and depends on no LEZ crate. Thin
  adapters map it onto a runtime: v0.3's `run_program(plan, apply)` (`programs/lez-msig`), and
  v0.4's transactional actors in their own workspace (`programs/lez-msig/lez04`, D13). Both are
  built; the v0.4 one is deployed on the 0.4.0-rc3 devnet.

## 2. The account

| | seed | what it is |
|---|---|---|
| program `P` | — | the program's account id (its `program_loader` header on v0.3) |
| the multisig `A` | `S = tagged("muster-msig/v1/state", create_key)` | public: `for_public_pda(P, S)`; private: `for_private_pda(P, S, npk, vpk, identifier)` with the group's keys |
| `(A, P)` shard | | `State` (§3), borsh |
| `(A, native)` shard | | the vault's balance |

**The program checks its own address.** Every instruction carries the multisig's *placement*:
`Public`, or `Private { npk, vpk, identifier }`. The plan re-derives `A` from `(P, S)` and the
placement, and refuses unless the state row is exactly that account. This is the
counterfeit-state defence. Without it, anyone could write a `State` naming another multisig's
create key at an account they control, and the program would grant that multisig's seed. For a
private PDA, an observer never sees the placement: instruction data stays inside the proof.

**Not drainable before initialisation.** Every instruction but `Create` requires an initialised
`State`, so funds sent to `A` before `Create` stay put. `Create` writes `State` once, into an
empty shard, at the address its placement derives.

**Group keys (private posture).** `npk`/`vsk`/`nsk` for `A` come from a Group Master Secret
(`SSK = H(dom ‖ GMS ‖ image_id ‖ S)`). Members receive the GMS sealed to their encryption
identity inside the room. The GMS lets a member **operate** the multisig (read it, build an
execution) but not **spend**: a PDA has no spending key, and the program grants `S` only after
the rules pass. The shared secret is a liveness tool, not a trust assumption about funds.

## 3. State

```
State {
  version: 1,
  zone: [u8;32],              // the zone tag, fixed at Create (§4, invariant 2)
  create_key: [u8;32],
  epoch: u64,                 // the config epoch: +1 on every configuration change (R.2)
  members: Vec<Member>,       // ≤ 32, distinct keys
  threshold: u32,             // the total weight of distinct approvers an action needs
  timelock_ms: u64,           // 0 = execute at once
  open_execution: bool,       // false: an EXECUTE member signs the execution too
  limits: Vec<SpendingLimit>, // ≤ 8
  usage: Vec<LimitUsage>,     // per limit: the period and what it has spent in it
  nonce_base: u64,            // nonces below are spent
  consumed: [u8; 32],         // a bitmap over nonce_base .. nonce_base+256
  queue: Vec<Queued>,         // ≤ 16 time-locked actions
}
Member        { key: [u8;32] /* BIP-340 x-only */, roles: u8 /* PROPOSE|APPROVE|EXECUTE */, weight: u16 }
SpendingLimit { id: u32, signers: Vec<[u8;32]>, threshold: u8, amount: u128, period_ms: u64 }
Queued        { nonce: u64, proposal_id: [u8;32], eta_ms: u64, expires_ms: u64 }
```

**Replay.** Every proposal names a nonce. Executing, queuing or cancelling it sets that nonce's
bit, and the window slides once the lowest bit is set. A nonce is used once, proposals may land
in any order inside the 256-nonce window, and the state stays bounded. No marker accounts are
needed.

## 4. What is signed

Every hash is a BIP-340 tagged hash, `tagged(t, m) = SHA256(SHA256(t) ‖ SHA256(t) ‖ m)`, over
borsh bytes.

```
Proposal { multisig: A, zone, epoch, nonce, action: Action, expires_ms, proposer: key }
proposal_id = tagged("muster-msig/v1/proposal", borsh(Proposal))
approval    = BIP-340 over tagged("muster-msig/v1/approve", proposal_id)
execution   = BIP-340 over tagged("muster-msig/v1/execute", proposal_id)   // when !open_execution
spend       = BIP-340 over tagged("muster-msig/v1/spend",   borsh(Spend { multisig: A, zone, epoch, limit, nonce, to, amount, expires_ms }))
```

The digest commits to **environment** (the zone tag), **account** (`A`), **slot** (epoch and
nonce) and **expiry**, which is muster's invariant 2 and RFP R.1's "exactly the action".

The zone tag is set at `Create` and is checked against every proposal. A LEZ message commits to
no chain id. The tag stops a multisig created twice on two zones, with the same program and
create key, from accepting each other's approvals. It cannot separate two replicas of one
chain's history; nothing can.

```
Action =
  | Transfer { to, amount }                      // native, out of the vault (custody_transfer)
  | Call { program, rows: Vec<(account, program)>, data }   // any program; granted S only
  | Config(Vec<ConfigChange>)                    // Add/Remove member, SetRoles, SetWeight,
                                                 // SetThreshold, SetTimelock, SetOpenExecution,
                                                 // AddLimit, RemoveLimit
  | Cancel(Vec<u64>)                             // nonces: unqueue and spend them
```

`Call` never targets the multisig program itself. It is granted exactly `S`, the multisig's own
seed, so it can act as `A` and as nothing else. The published v0.2.4 program let a quorum pass
any seed (exo-325).

## 5. Instructions and the rules

| instruction | the rules (all in `msig_core`) |
|---|---|
| `Create { create_key, zone, config }` | `A` is the PDA its placement derives; the shard is empty; the config is valid (below) |
| `Execute { proposal, approvals, executor?, at_ms }` | the proposal is for `A`, this zone and **this epoch**; the nonce is unspent and in the window; the proposer is a PROPOSE member and signed; the distinct APPROVE signers' weight ≥ threshold; every signature verifies; if `!open_execution`, an EXECUTE member signed the execution; the time lock is 0, or the action is a `Cancel`; the nonce is spent; then the action runs |
| `Queue { proposal, approvals, executor?, at_ms }` | the same checks; the time lock is > 0; the nonce is spent; `Queued { eta = at_ms + timelock }`, with `eta < expires` |
| `ExecuteQueued { proposal, executor?, at_ms }` | a queue entry has this nonce and `proposal_id`, and `at_ms ≥ eta`; it is removed and the action runs. **The epoch is not re-checked** (the R.2 cutoff is the queue) |
| `Spend { spend, approvals, at_ms }` | the limit exists; at least its threshold of its own signers signed, all distinct; the period `p = at_ms / period_ms` has `used + amount ≤ amount` (the counter resets when `p` advances); the nonce is spent; the native transfer runs. No time lock |

**Time.** A program reads no clock. Every `at_ms` is a claim the plan binds with a validity window
the sequencer enforces:

- `Execute`: `[ —, expires )`.
- `Queue`: `[ —, at_ms ]`. The transaction lands no later than `at_ms`, so `eta = at_ms + timelock`
  is at least the real queue time plus the lock: pessimistic, never early.
- `ExecuteQueued`: `[ at_ms, expires )` with `at_ms ≥ eta`.
- `Spend`: `[ p·period, (p+1)·period ) ∩ [ —, expires )`.

Windows are public even in a private transaction, so clients round them to the minute (exo-a99, #407).

**A valid config.**
- 1 ≤ n ≤ 32 members, with distinct keys and every weight ≥ 1.
- 1 ≤ threshold ≤ the total weight of the APPROVE members.
- At least one PROPOSE member, and, unless `open_execution`, at least one EXECUTE member.
- Each limit's signers are members, with 1 ≤ k ≤ |signers|, a period > 0 and an amount > 0.
- Limit ids are distinct; at most 8 limits.
- `timelock_ms` ≤ 365 days.

A config change whose result is invalid is refused whole. Removing a member who signs for a limit
is refused unless the same change removes or replaces that limit.

**Roles (RFP F.6), and what each guarantees.**
- **PROPOSE.** The program refuses an action its proposer did not sign. A proposing key need not
  be an approving key: the proposer's signature counts toward the threshold only if they hold
  APPROVE.
- **APPROVE.** Only APPROVE signatures count, weighted.
- **EXECUTE.** With `open_execution` off, the program refuses an execution an EXECUTE member did
  not sign. In the private posture, executing also needs the group keys to build the proof, so it
  is limited to whoever holds the GMS whatever the role says.

**R.2, precisely.**
- Every approval commits to the epoch. Any config change bumps the epoch, so every approval
  gathered before it stops counting at once.
- The cutoff is **the queue**. An action already queued stays executable after a later config
  change, member removal included.
- The current quorum can `Cancel` it at once: cancels are never time-locked. The UI offers the
  cancel alongside every removal that leaves a queued action behind.
- What a removed member can still do: see §7.

**Error messages (U.7).** Every refusal is a `MsigError` with a stable code and a sentence
(`stale-epoch: approvals were gathered under epoch 3; the multisig is at epoch 4`). The host runs
the program locally before proving (§6), so a refusal shows up in seconds, not after a proof.

## 6. Executing

- **Public posture.** Anyone may send the transaction and pay its fee; muster sends it from the
  executing member's own funded account. Members' approval keys and every action are public.
- **Private posture.** A member holding the GMS builds one privacy-preserving transaction:
  - It consumes `A`'s note and writes its new one.
  - The recipient's credit is a private Init (hidden), or a deferred public effect (amount and
    payee visible).
  - The program's image claim is **Undisclosed**: the program is deployed immutable, so a claim
    says only "some immutable program".

  Before proving, the host executes it with no proof and reports any refusal. Proving takes
  minutes and runs in the background with visible progress. Every execution consumes `A`, so
  executions serialise, and a proof built against a stale `A` is rebuilt.

**The prover is a Logos module, one per LEZ line** (exo-efa, exo-cc7). The two lines cannot share
one build, so a host may hold both, and muster calls the one its zone needs:
- `lez_msig_module` (0.1.x, `programs/lez-msig/module`) for v0.3;
- `lez_msig_v04_module` (0.2.x, `programs/lez-msig/lez04/module`) for v0.4.

Each wraps its line's `exec_request`, the same function its `msig_exec` CLI runs, so the two
cannot drift. It holds no key:
- `exec` takes the program's instruction (`msig_core::Instruction`, borsh), the group secret and
  `A`'s current note. It reads the note's membership proof from the user's sequencer, proves,
  sends, and answers with a job; `job` then gives the hash and the new note.
- `fund` proves a deposit, a native transfer from a member's public account into `A`, from the
  payer's public key alone. It answers with the message hash to sign. The member's keystore
  signs it, and `send` checks the signature against the message, then sends.
- One proof runs at a time on its own thread. A job is readable only by the caller that
  submitted it, and `forget` drops its decrypted note.
- `scan` recovers the newest note from the chain with the group's viewing keys, for a member whose
  room never received it.
- On v0.4, every request also carries the fee account's note (`feeNote`) and answers with its new
  one, and `topup` funds that account from a member's public account (D17). Muster reads its
  balance from the newest fee note and sets it against what the next private transaction reserves
  (LEZ's private fee at `getFeeState`'s ceilings, as the executor prices it), so a member sees it
  run low before a proof fails (exo-8ef, `lez/msig_gas.nim`).
  - `recipients` seals a payment to a private payee's `Recipient`.
  - `collectFrom` collects deposits paid to the vault from outside the group, from a cursor the
    room keeps beside each note.

In muster, `wallet/msig_prover.nim` is the seam (`MsigProver`), `msig_prover_lp.nim` reaches the
module over `lp_*`, and `CliMsigProver` runs `msig_exec` for tests without a host.
`wallet/lez_msig_private.nim`'s `MsigPrivate` is the public chain seam with three differences:
- it reads the state from the newest note;
- it sends through the prover;
- it follows a job, then its transaction.

So the settlement's rules (approvals, epoch, nonce, time lock) are one piece of code for both
postures. A refusal surfaces while proving, and nothing is sent.

## 7. What each observer sees (U.5, Privacy 1–3)

The full per-action table for both postures and both LEZ lines, the cross-layer correlations,
and the requirement-to-test map are in [`lez-msig-guarantees.md`](lez-msig-guarantees.md). This
section is the summary.

**Private posture.**

| item | chain | store node / fleet | room member | removed member |
|---|---|---|---|---|
| existence | v0.3: no (a nullifier and a commitment per execution). v0.4: the vault's address is published as a recovery binding at Create and named by outside deposits, so its existence (not that it is a multisig) is visible | no | yes | yes |
| member set, threshold | no | no | yes | until rotation or migration (state is readable with the GMS) |
| who approved | no | no | yes (signed in the room) | until rotation or migration |
| pending proposals | no | no | yes | until the room re-keys them out (F-16), once the removal is final; not at all while they are still in another lez-msig of the room (§8) |
| action payload | no; a public payee's credit shows payee and amount, a private payee's (v0.4) is sealed to it | no | yes | until rotation or migration |
| vault balance | no | no | yes | until rotation or migration |
| execution linkage | unlinkable notes; window bounds are public | timing of room traffic | yes | — |
| coordination content | no | no (sealed) | yes | no, from the epoch after removal (F-16) |
| co-signing graph | no | room traffic metadata; mixnet is opt-in (`mix`) | yes | what they saw |

- **Removal.** Removing a member re-keys the room forward at once (F-16). The GMS cannot be
  revoked, so the removed member can still *read* the multisig's state, and can *stall* it by
  consuming `A`. They can never *spend*. How the others leave them behind depends on the line:
  - **v0.4, rotation (D19, exo-3dc; the program side is built, the room's flow is not).** The approval that removes a member also retires
    the vault, hands its configuration to a successor at a new PDA under a new GMS, and moves the
    balance there, in the same transaction.
  - **v0.3, migration (D11).** The remaining members create a new multisig under a new GMS, then
    move the vault to it with a `Transfer` the old quorum approves.

### D19 in detail: rotation on removal (v0.4, exo-3dc)

After James Zaki's 0.4 multisig (`jzaki/jz-progs`, `example_progs/multisig/src/rotate.rs`), mapped
onto signatures instead of seats.

**Built (program side, 2026-11-26).** The rules are in `msig_core` (`apply_stored`, `adopt`,
`forward`; `core/tests/rotation.rs`). The v0.4 guest and host are in `lez04` (`rotate_tx`, `sweep_tx`,
`fee_sweep_tx`; `host/tests/v04_rotation.rs`, on LEE's own state with dev-mode proofs). The guest is
built into `lez04/artifacts/msig-next.bin` and is **not deployed**. Muster's room flow is still to do.

**The action.** One new `Action` variant, appended (borsh tag 4):

```
Action::Rotate { create_key: ck', successor: A', changes: Vec<ConfigChange> }
```

It is a proposal like any other: approved by the quorum, executed with `Execute`, or queued under
a time lock and run by `ExecuteQueued`. `changes` is applied to the current configuration exactly
as `Config(changes)` would be, and the result must be valid. Removing a member is
`changes = [RemoveMember(k), …]`, but the core does not insist on a removal: an add the members
want hidden from the history, or a suspected leak of the GMS, rotates the same way.

**The successor.**
- Its create key `ck'` is fresh (the proposer's client draws it), so its seed is
  `S' = tagged("muster-msig/v1/state", ck')`. A new seed is required, not a style choice: LEE binds
  each `(program, seed)` to one account per transaction (`bind_family`), and the rotation grants the
  old seed (moving the balance) and the new one (the handover) in the same transaction.
- Its account is `A' = for_private_pda(P, S', npk', vpk')`, with `npk'`/`vpk'` from the new group
  secret GMS'. The proposal names `A'` and `ck'`, never the keys, so a member who sees the proposal
  learns an address it cannot derive keys for.
- Its fee account (D17) is `derive_regular_shared_account_keys(fee_derivation_id(ck'))` under GMS':
  both inputs changed, so it is a new account the removed member cannot touch.
- Its state: the old state with the changes applied (so the epoch is `e + 1`), its own create key,
  the spending limits' usage and the nonce window carried over (a limit spent this period stays
  spent, a nonce used stays used), and **an empty queue**.
- The core refuses a successor equal to the multisig itself, and a `ck'` equal to its own.

**In the transaction** (the v0.4 actor model):
1. The root call `Execute { proposal: Rotate, … }` passes every check of §5. The core returns the
   old account's new record, **retired**, and a handover. The handler writes the record, then sends:
   - `Handover { to: A', state }` to `(A', P)`, granting `S'`;
   - `ReadState` to its own native balance.
2. At `(A', P)`, the handover is accepted only from this program (`from` is one of its actors), only
   authorized (the sender granted `S'`, which LEE proves is the seed of this account's witness), and
   only onto an empty shard. The core checks the state names `A'`'s create key and a valid
   configuration, and writes it.
3. The native balance answers the old account with its balance. The handler, at a retired record,
   sends the whole balance to `A'` (`custody_transfer` under `S`). The credit is promoted into `A'`'s
   new note in the same proof.

One transaction, one proof, two multisig accounts and two balances. The removed member never holds
GMS', so they cannot read or build anything on `A'`.

**A retired account** stores a `Retired { create_key, epoch, successor }` record in place of
`State`. Its first byte is `0x52` where a `State` has its version, `1`, so `State`'s layout is
unchanged and every existing note decodes as before. A retired account refuses every instruction
(`retired`) except `Sweep`, a new `Instruction` variant (tag 5) with no signatures: it reads the
balance and forwards all of it to the recorded successor, which is the only place it can go. Anyone
who can build the transaction may send it, the removed member included; all it can do is finish the
move the quorum approved.

**Late deposits.** A deposit made to the old address after the rotation (a member who had not
caught up, or an outside payer using the old address) lands in the retired account. A `Sweep` in a
transaction of its own forwards it to `A'`. The rotation transaction also registers `A'`'s recovery
binding, so outside payers can be given the new address.

**The fee account.** The old fee account `F` cannot move in the rotation's own transaction: a v0.4
transaction has one root call, and the program neither holds nor sees `F` (a regular account
authorized by a key from the GMS, not the program's PDA). Making the program forward it would need an
account the members never approved in the instruction, and a role over an account the program does
not own. So the executor sends two transactions:
1. **the fee sweep**: `F`'s whole balance transferred to `F'`, witnessed with `F`'s authorization key,
   `F'` paying this transaction's fee out of the credit (as a top-up does);
2. **the rotation**, its fee paid from `F'`.

This opens no new window: any GMS holder, the removed member included, could already drain `F`
(D17's stated cost), and after step 1 there is nothing left there.

**What the room must supply** (Muster's side; out of this program change):
- a fresh `ck'` and a fresh GMS', generated by a remaining member's client (the proposer's) and sealed
  to each remaining member in the room. Never to the removed member, never to the program: the program
  sees only `A'` and `ck'`.
- `A'`, derived from `(P, ck', GMS')`. Every approving member's client re-derives it from a GMS' it
  holds and refuses to sign otherwise. The program cannot check this, and an `A'` only the proposer
  can derive would hand the vault to an account the others cannot operate.
- After the rotation, the new notes (`A'`'s and `F'`'s), sealed to the remaining members. The old
  account's last note is the retired record.

**What is lost, and said on the card.**
- Queued actions do not carry over, so a rotation also cancels everything queued, which the same
  quorum can already do at once (D5).
- Approvals gathered for the old account never count on the new one: they name `A` and its epoch.

**Public posture.** The program does not refuse a public rotation, but a public multisig has no
shared secret, so `RemoveMember` in place is enough. Muster offers rotation only for the private
posture.

**Signing bytes: no tag bump.** D19 first said the tags move to `v2`; they do not.
- Appending `Rotate` to `Action` and `Sweep` to `Instruction` changes no existing value's bytes.
  Every `Proposal`, `Spend` and envelope encodes byte for byte as before, so every approval, execution
  and spend signature means what it meant. Muster's vectors (`module/tests/vectors/lez-msig/`) are
  unchanged.
- A tag separates purposes, so a signature for one purpose is worthless for another. A rotation is a
  proposal, and its id is hashed under the proposal tag like any other. borsh's variant byte already
  makes a `Rotate` proposal's bytes differ from every older value.
- Invariant 2 holds as for every proposal: the id commits to the zone, the account `A`, the slot
  (epoch and nonce) and the expiry, and now also to `ck'` and `A'`.
- A program built before D19 cannot decode variant 4, so it refuses a `Rotate`. Because a proposal
  names `A`, which derives from the program id, a `Rotate` signed for one program's multisig is
  worthless at another's.
- The handover is a message from the program to itself, never signed.

**A new program.** The guest changes, so its image id, and with it the program id and every private
PDA, change too. Multisigs on the deployed 0.4 program (the devnet's) keep working there, without
rotation, and move to the new program by D11's migration. v0.3 has no actor messages, so its adapter
refuses `Rotate` and `Sweep` (`rotation-unsupported`) and keeps D11.
- **Correlation across layers (Privacy-3).**
  - Room messages and executions are separate traffic. An observer of both sees the room's sends,
    which the store node sees as sealed envelopes on one topic, and executions at about the same
    time.
  - Nothing on chain names the room. The binding between a member's LEZ identity and their room
    identity exists only inside the room (§8).

**The RPC provider** (the member's own sequencer endpoint) sees more than the chain. Before every private transaction, the v0.4 executor reads the program's account and its mirror commitment, and the membership proofs of the notes it spends. So the RPC learns which program runs (D18 hides it from the chain only), and can link one multisig's transactions together. Each member choosing their own RPC limits who learns this.

**Public posture.** Everything except coordination content is public; that stays in the room.

The full per-action, per-observer table, and the cross-layer correlations, are in [`lez-msig-guarantees.md`](lez-msig-guarantees.md).

**Selective disclosure (§ Privacy Architecture 2–3).**
- **A narrow audience.** Give an auditor the PDA's viewing key. On v0.3 that is `(nsk, vsk)`:
  they can read and also stall. On `dev` the viewing secret is separate from `nsk`, so they can
  read only.
- **A wide audience.** Muster's signature-audit export (`coordination/audit.nim`) gives the
  room's record of who approved what, verifiable from the file alone.
- **Ongoing assurance.** Re-export at any time. A disclosure shows `A`'s current commitment, and
  the receiver checks it against the chain's commitment set.
- **What an audience learns.** Everything the key decrypts, from then on.

## 8. The room (F.9, S.2)

The coordination room is muster's room. Each multisig is created *from* a room.

1. **Bind.** Each member derives an approval key in their keystore (label
   `lez-msig/<room>/<n>`) and discloses it in the room. The disclosure is author-signed by their
   room identity, and the approval key signs the room's binding statement back. So the binding
   is mutual and lives only in the room.
2. **Create.** The creator assembles the config from the disclosed keys and generates the GMS.
   They send `Create` (public posture), or prove it (private). Then they seal the GMS to each
   member in the room.
3. **Propose / approve.** A proposal is a room intent whose effect is the `Proposal`. An approval
   is a room contribution carrying the BIP-340 signature. The driver re-derives `proposal_id` from
   the effect and verifies the signature against the member's disclosed key, the same checks the
   program will make (invariant 1). The room holds no authority over validity: the program's
   check is the only one that counts.
4. **Execute / queue / cancel.** Any member with the keys settles. The card shows the queue's ETA
   and the expiry.
5. **Reconcile (built, exo-0d3.13; `coordination/msig_members.nim`).** On every executed config
   change, the room follows the program:
   - **The room's copy of the config.** The disclosed config, then each config proposal the room
     saw reach final, applied as the program applies it (`applyChanges`, the core's
     `apply_changes`), one epoch each. So an added member's approval counts in the room, and a
     removed member's stops counting, with no re-disclosure.
     - A change applies when its proposal names the epoch the fold has reached, or an earlier
       one no older than the disclosure (a queued change executes after its epoch).
     - A change made outside the room leaves the room's copy behind until the account is
       disclosed again.
     - Settlement re-reads the chain either way.
   - **Who reads the room.** A removed member who is in no other lez-msig of the room is
     evicted, and the room re-keys forward (F-16).
     - One client does it, so the epoch never forks: the removal's proposer's, or, when someone
       removed themselves, the lowest remaining member's.
   - **Adding a member.** A member added later must already be in the room and have shared an
     account (exo-1f9) for the add to name. Their approval key is that account.
   - **Private multisigs.** The add's proposer seals the group secret and the newest note to the
     added member. Notes go to the members now, and a removed member's notes stop counting.
   - **Queued actions.** One proposed by a member since removed survives (the R.2 cutoff is the
     queue). The queue flags it (`proposerRemoved`) beside its cancel.

**Spending limits from the room (built, exo-0d3.12).** A limit is added like any config change:
through the quorum and the time lock. A spend under it is a room intent of its own kind,
`muster.effect.lez-msig-spend.v1`:
- **What is signed.** The effect is the spend's exact bytes. Each contribution is a BIP-340
  signature over `spend_msg` by one of the limit's signers, and only they count.
- **The threshold** is the limit's, not the quorum's.
- **Settlement** reads the state, then sends one `Spend` for the current period, with no Queue
  even under a time lock. It refuses before sending:
  - a spend over what the period has left;
  - a stale epoch;
  - a spend within two minutes of the period's end (it would land outside its window).
- **Nonces.** Spends and proposals share the nonce window.
- **The card** reads a spend in words from its bytes, naming the limit and saying no quorum is
  asked.
- **Tested** against the real program in `lez_msig_live_e2e` §8: a limit added, one signer
  spending alone, and an over-limit spend refused.

**Approval keys from accounts members shared (built, exo-1f9).** By default each member's
client derives a fresh approval key for each multisig. A member may instead share an account
of their own with the room (`coordinate_disclose_my_account`): its key signs a hash-input
record of (room, member, chain, kind, key), so it counts only for that member and only in
this room, and the disclosure is author-signed. The opener may then pick, for any member, one
of the accounts that member shared (`lez_msig_open {accounts}`). A picked account counts as
that member's join. Their client finds its keystore label by deriving its own candidates
(`crypto/account_labels.nim`), so the room never sees a label. The cost is linkability: the
public posture puts every member key on chain at creation, so one account used in several
multisigs links them. The fresh key stays the default.

**The private posture in the room (built, exo-efa).** The opener's `lez_msig_open` (private
unless it says `private: false`; refused, naming the prover to install, when the zone's line has
none, exo-c0c) generates the GMS and seals one copy to each invited member's room identity. Each copy is
author-signed, and only the opener's counts:
- `lmsig/<ck>/gms/<member>` carries the sealed GMS.
- The opener's client creates the multisig through the prover. Once the chain includes the
  Create, the client seals the note, the multisig's decrypted account, to every member as
  `lmsig/<ck>/note/0/<member>`. It then discloses the account with placement `private`.
- After every later transaction the chain includes, the member who sent it seals note `n+1`.
  Only one transaction can spend note `n` (its nullifier), so each number has one note.

Every member reads the multisig from the newest note. No one scans the chain, and anyone else in
the room holds no copy. A member holding the GMS checks the disclosed address through the
prover's `derive`; to the rest of the room it reads as unknown.

**Recovery (built, exo-abc).** A member who landed a transaction may go away before sealing
its note. The prover's `scan` then reads every block's private actions and decrypts the
multisig's notes with the group's viewing key; the newest is the state, because each spends the
one before. The finding member seals it into the room like any other note. It starts by itself
when a private settlement fails, and a member can start it ("Read it from the chain";
`lez_msig_recover`). It sends nothing.

A payment's credit to a public payee is a deferred public effect, so it can land a block after
the multisig's note. Muster judges the multisig by its note and never by the payee's balance.

**Real proving from a room (run 2026-11-19, exo-0d3.15).** `module/tests/lez_msig_private_e2e.nim`
ran all nine sections against a local zone started without dev mode
(`MUSTER_LEZ_REAL_PROOFS=1 infra/lez/localnet.sh`), which verifies real receipts. Every private
transaction was really proved on a 64-core machine, and the run took 765 s:
- create;
- a deposit;
- a 2-of-3 payment;
- a refusal while proving;
- a note recovered from the chain;
- a payment from that note.

The public testnet run waits on the testnet funder.

Every view of the room is the fold over its signed log.

- **What a participant can do against the room.** Withhold, reorder, replay, inject, or show
  members different views.
- **Why it does not matter for validity.** The program re-verifies everything. Replay is spent by
  the nonce, injection has no valid signature, and a stale view yields approvals for a stale
  epoch, which the program refuses.
- **What remains is liveness.** A member can withhold their own approval, which is their right,
  or refuse to relay.

**S.2 says the chat module; this is a deliberate deviation, narrowed since.** Each multisig's
deliberation now runs in a `chat_module` group that follows the program's members (PR #388;
removal proven on the live fleet with a patched module). Proposals and approvals stay on Muster's
room until the chat module reaches parity; that full binding is the accepted proposal's M4
(exo-13f). Why they stay:
- Chat 0.3.0 has no member removal in a release, so the reconciliation above cannot be done on it.
- It sends the room id in the clear.
- It registers key packages with a central HTTP service.
- Muster's room has forward re-keying on admission (F-16), a sealed topic the store node cannot
  attribute (exo-661.7), and an exportable proof (`log/proof.nim`).

The `ConversationCrypto` seam is where a chat-module binding goes once chat ships removal
(ADR-010).

## 9. Decision log (S.14)

| # | decision | options | chosen, because |
|---|---|---|---|
| D1 | how members approve | seats (an actor per member, 2k proofs); on-chain votes (the v0.3 port); off-chain signatures verified in-program | signatures: one proof per action, no member on chain, and the room is already a signed log |
| D2 | where state and funds live | separate state and vault PDAs; one PDA, two shards | one PDA: one note to consume, one address to check |
| D3 | approval scheme | ed25519 (`sequencer_stake`'s); BIP-340 | BIP-340: muster's keystore signs it, and with risc0's accelerated k256 (patched in our guest only) about 0.28M cycles per verify against several million for unaccelerated ed25519 on v0.3 |
| D4 | replay | consumed-id set; initialise-once marker accounts; nonce + 256-bit window | the window: bounded state, any order, no extra accounts in a private transaction |
| D5 | the R.2 cutoff | at execution; **at queue**; any change voids all | at queue, with immediate cancels: a time lock is a promise to the members, and the current quorum can still stop it |
| D6 | time | the clock program; validity windows | windows: no extra accounts, and a pessimistic ETA |
| D7 | posture | two programs; placement | placement: one audited program, and the posture is the account kind |
| D8 | runtime | v0.3 only; `dev` only; a core plus adapters | core plus adapters: v0.3 is what runs today, `dev` is what 0.4 will run, and it is still moving |
| D9 | the coordination layer | chat_module 0.3.0; muster's room | muster's room, until chat ships removal (§8) |
| D10 | counterfeit state | trust the state row; re-derive `A` from the placement in the plan | re-derive, refusing any other row (§2) |
| D11 | removal | revoke (impossible, there is no key revocation); migrate | migrate, with the GMS's limits documented (§7) |
| D12 | spending limits | any asset; native only | native first; a token limit is a `Call` whose decoded amount the limit would have to trust, which waits on the registry (U.6) |
| D13 | the LEZ 0.4 port (proposal M1) | port in place; a second program beside the first | a second adapter in its own workspace (`programs/lez-msig/lez04`) over the SAME `msig_core`: v0.3 and v0.4 cannot share a dependency graph, and v0.3 is what runs today. The new image id gives a new program id and new private addresses, so v0.3 multisigs move by the migrate path (D11), never in place |
| D14 | who may call the multisig on 0.4 | any sender; root calls only | root calls only (`from` is None): v0.4 lets another program, or a cross-zone message, send to `(A, P)`. The approvals would still bind, but nothing needs that path, and refusing it keeps the attack surface v0.3's |
| D15 | a `Call` on 0.4, where a message goes to one actor | a core change (`to: Row`); an adapter convention | the convention: `rows[0]` is the target, an account of the called program; the transaction declares the other rows. The digest already commits to every row, so members approve the full list, and the core stays as audited |
| D16 | inherited seed authority on 0.4 | forbid `Call`; allow it and say what it means | allow it and say so: on 0.4 a seed granted to a call's target reaches everything the target calls, so a `Call` hands the vault to that whole call tree. The `targets` allowlist is the guard, and the card must name it. Spending limits never bound a `Call` |
| D17 | the fee on a private execution (0.4: no longer exempt, paid in the proof by a private account with an authorization key; a PDA cannot) | the executor's own private account; a group fee account from the GMS (`FeeOnly`); the vault through a program-sent credit (unverified, a core change) | **decided 2026-11-20:** a group fee account derived from the GMS (LEE's `derive_regular_shared_account_keys`, id `SHA-256("lez-msig/v1/fee-account" ‖ create_key)`, `msig_host04::fee_derivation_id`), witnessed `FeeOnly`, so no member's account appears and the module still receives no key. Shown on LEE 0.4.0-rc3 state with dev-mode proofs (`lez04/host/tests/v04_private_fee.rs`): it pays a private Create's fee, a nullifier-key witness cannot pay (`FeePayerWithoutAuthorization`), and the PDA cannot pay its own. Its cost: members top it up (`Msig::top_up_fee_tx`: a public account's transfer promoted into the fee account, which pays that transaction's own fee out of the credit, so a group starts with no funds), and anyone holding the GMS (a removed member included) can drain it. D19's rotation moves to a new GMS, hence a new fee account; the rotation should sweep the old one in the same transaction |
| D18 | the program's identity on a private execution (0.4 discloses it by default) | disclosed; deployed immutable and proved undisclosed; a shadow program | **decided 2026-11-20:** deploy immutable and prove with an undisclosed image claim (`Msig::with_undisclosed`, LEE's `ProgramCatalog::with_undisclosed`), which keeps v0.3's property and lets the public posture exist at the same program. Shown on LEE 0.4.0-rc3 state (`lez04/host/tests/v04_undisclosed.rs`): a default proof names the program; an undisclosed one carries only a commitment-set root, the program's account appears nowhere in the transaction, and the zone accepts it; a claim against a header the zone never saw is refused. The devnet program is already immutable |
| D19 | removing a member when the group secret cannot be revoked (0.4) | migrate in a separate flow (D11); rotate in the program | **decided 2026-11-26** (the accepted proposal; to build: exo-3dc): rotate in the program, after James Zaki's 0.4 multisig (`jzaki/jz-progs`, `example_progs/multisig`). The approved removal retires the vault and hands its config to a successor at a new PDA under a new group secret, moving the whole balance, in the same transaction. A retired vault refuses everything but a sweep that forwards late deposits. It replaces D11's separate migration on 0.4. **Refined 2026-11-26** (§7, "D19 in detail"): a core change, but an appended `Action::Rotate` and `Instruction::Sweep`, so no existing bytes change and the tags stay `v1`; the successor takes a fresh create key, because LEE binds one account per `(program, seed)` in a transaction; the old fee account is swept to the new one in the transaction before, because a transaction has one root call and the program does not hold the fee account |

## 10. Measured (RFP P.1, P.2)

`programs/lez-msig/BENCHMARKS.md`, real proving on an idle 64-core EPYC:

- A private payment carrying M approvals proves in about **111 s + 12.0 s · M** on v0.3
  (2026-11-19) and **182 s + 11.5 s · M** on v0.4 (2026-11-20). On v0.4 the extra base is the
  fee account's witness (D17).
- The transaction is about 228 KB on v0.3 and 229–238 KB on v0.4, flat in M.
- On v0.4 a private transaction's fee is flat in M too: about 5.07M at base fee 8.
- RISC Zero's accelerated k256 is 2.9× faster than stock (439 s for one signature, unaccelerated).

M ≥ 5 is viable. The ceiling is the 32-member limit, not the block. A laptop-class figure is
still to come (exo-0d3.15).

## 11. Sources

- RFP-005, and the nine bids reviewed on 2026-10-23 (`logos-co/rfp` #211–#233).
- LEZ v0.3.1:
  - `run_program`, validity windows: `lee/state_machine/core/src/program/mod.rs`
  - private PDAs: `:302`
  - group keys: `lee/key_protocol/src/key_management/group_key_holder.rs`
  - `custody_transfer`: `core/src/native_token.rs:127`
  - the in-guest threshold precedent: `lez/programs/sequencer_stake/src/main.rs:319`
- LEZ `dev` @ `7cba743a`: the actor handler (`program/mod.rs:736`), and PR #1001's
  `catalog/multisig.md`.
