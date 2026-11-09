# The quest record program (exo-267.7)

Status: **built and run on a local v0.3.0 chain, 2026-11-09.** The program is
`programs/lez-quest` (its rules tested in process), muster reads it in `module/src/lez/quest.nim`
(held to the crate's vectors), and `quest_e2e` ran it on a local zone beside the multisig
port: a quest a person issued and closed, and one a 2-of-3 issued and closed by vote, the
vault's grant carrying into the bounty's transfer as §4 read from the executor. Its record
holds the bounty itself (no separate escrow PDA), and Close carries the taker and bounty it
pays, since plan cannot read the record; apply checks both. The room side is exo-267.8, and the plan is
[logos-world-plan.md](logos-world-plan.md) Phase 1.

## 1. What it is for

A circle issues quests through its LEZ multisig and attests to them there. The chain should keep a
record of each quest that anyone can read, and that names nobody without their signature. The
multisig alone cannot do that: an executed proposal shows that the members agreed to a call, but not
what the quest was, who took it, or who confirmed it. The quest program keeps that record, and its
rules are enforced by the chain, not by muster.

## 2. The record

One record per quest, at a PDA of the quest program `Q`:

```
record = for_public_pda(Q, seed)
seed   = SHA-256("/lez-quest/v0.1/Record/" padded to 32 ‖ issuer ‖ quest_id)

QuestRecord {
  issuer:     [u8; 32],          // the issuing multisig's vault
  quest_id:   [u8; 32],          // chosen by the room (§5)
  terms_hash: [u8; 32],          // the terms, hashed by muster (§5); the text stays in the room
  bounty:     u128,              // native LEZ, 0 for none
  confirmer:  [u8; 32],          // who confirms it is done
  taker:      Option<[u8; 32]>,  // named at Open, or None: anyone may accept
  status:     Open | Accepted { taker } | Confirmed | Closed | Cancelled,
}
```

The PDA formula and seed style are the ones the v0.3 multisig port uses
([lez-multisig-v03.md](lez-multisig-v03.md) §2), so muster's `for_public_pda` derivation already
covers it.

## 3. Instructions

Each instruction names the record as a row and the account whose authorization it needs. On v0.3 a
signer passed only to authorize is a row selecting the program's own shard of that account, with no
effect on it (lez-multisig-v03.md §8).

| instruction | who must be authorized | record before → after | moves |
| --- | --- | --- | --- |
| `Open { quest_id, terms_hash, bounty, confirmer, taker }` | the issuer (the vault, granted by the multisig's Execute) | empty → Open | `bounty` from the issuer's account to the record account (§4) |
| `Accept { issuer, quest_id }` | the taker (their own transaction) | Open → Accepted; must equal the named taker if one was named | — |
| `Confirm { issuer, quest_id }` | the confirmer (their own transaction) | Accepted → Confirmed | — |
| `Close { quest_id, taker, bounty }` | the issuer (a second vote) | Confirmed → Closed; apply checks the taker and bounty | the record account's bounty to the taker |
| `Cancel { quest_id, bounty }` | the issuer | Open or Accepted → Cancelled | the bounty back to the issuer |

What the chain refuses, and the program's tests must show:

- an Accept signed by anyone other than the named taker;
- a Confirm by anyone other than the confirmer;
- a Close before Confirmed;
- an Open whose issuer row is not authorized;
- any change to a Closed or Cancelled record.

So nobody is named as taker or confirmer of a quest without their own signature (invariant 9, held
by the chain).

## 4. The bounty

A chained call carries its caller's grants: LEZ v0.3.0's executor
(`lee/state_machine/core/src/execution_state.rs`) pushes every chained call with
`grants: grants.clone()`. When the multisig's
Execute calls `Q` with the vault's seed, `Q` is granted the vault, and `Q`'s own chained call to the
native program may move it. So:

- **Open** takes the bounty out of the issuer's account into the record account's own
  native shard, in the same transaction. The bounty is set aside at issue, visibly, and a taker
  can see it before accepting.
- **Close** pays the bounty to the taker. **Cancel** returns it to the issuer. Both move `Q`'s own
  PDA, which `Q` authorizes with its own seed.

Each quest step is therefore one multisig vote, or one member's own transaction, and paying is
atomic with the record changing.

The grant carrying through has a cost that applies to the multisig already: any program a proposal
calls with the vault's seed can move the vault, directly or through its own chained calls. A
proposal commits the whole call, and the room reviews it (the S5 re-read), so the members are
approving `Q`'s code by its account id. The card should say so.

Paying at close straight from the vault, with no escrow, is the alternative. It is simpler, but it
leaves the bounty unreserved and the pot can be spent before the quest closes. Which one is a
decision for Jarrad (plan §Decisions); escrow is the default here.

## 5. What muster supplies

- **`terms_hash`**: a domain-separated hash-input record over the terms' canonical CBOR (task text,
  bounty, confirmer, taker, expiry if any), invariant 5. Publishing the terms later lets anyone
  check them against the record.
- **`quest_id`**: SHA-256 over a domain tag, the issuer, the terms hash, and the room intent id that
  proposed the quest. It is unique per issuer and links to nothing outside the room.
- **The S5 re-read**: before a member votes on Open or Close, muster reads the record (and the
  record account's balance) and refuses on any difference from what the room reviewed.
- **Readiness**: each of Accept and Confirm is a public transaction, paid by its signer in native
  LEZ. The card names this before a newcomer is asked to confirm a welcomer's quest.

## 6. Open questions

1. **Close on confirm.** Should the issuer be able to choose, at Open, that the confirmer's Confirm
   closes and pays with no second vote? It suits a person-given quest, where the helped person's
   word is the attestation. Default: no, both are needed (the plan's default).
2. **Events.** v0.3 plans can emit events, and the executor passes them to the backend at
   completion. Whether they can be read back from a sequencer later is unchecked, so the record is
   a shard, not an event.
3. **Expiry.** A validity window on Accept and Confirm, so a quest nobody finishes can be cancelled
   by anyone after its deadline, not only by the issuer.
4. **Where it lives.** In this repo at `programs/lez-quest/` (a Rust workspace beside the module,
   built with the risc0 toolchain like the multisig port) until it has a second user, then in its
   own repository.

## 7. Acceptance

- The program's own tests on a local v0.3 zone (`infra/lez/localnet.sh`): every refusal in §3, the
  bounty moving on Open, Close and Cancel, and a Closed record that nothing changes.
- Vectors from the program's crate (the borsh of a record in each status, every instruction, the
  PDAs). Muster decodes them byte for byte, as it does `tests/vectors/lez-multisig-v030`.
