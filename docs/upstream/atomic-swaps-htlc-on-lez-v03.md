# The atomic-swaps HTLC on LEZ v0.3: what changes

**For:** anyone moving [`logos-co/atomic-swaps-poc`](https://github.com/logos-co/atomic-swaps-poc)
(the ETH ↔ LEZ swap) off LEZ v0.2.2, or writing any LEZ escrow on v0.3.
**From:** the Muster team (`corpetty/muster`).
**Date:** 2026-10-02. **Status:** notes offered, not an ask. Nothing here is built on
the swap repo's side.

## One line

LEZ v0.3 changes four things that the HTLC relies on:

- **Fees.** Every public transaction now pays one, so a taker buying their first LEZ
  can't pay to claim it.
- **Refused transactions.** A refused call is now included and billed, so a race at the
  timelock costs the loser money.
- **Balances.** Balances belong to the native token program, so Claim and Refund become
  chained transfers.
- **Account data.** A program's planning step can't read account data, so the escrow's
  checks move into one-account steps.

We hit all four porting our own escrow-shaped program (a LEZ multisig: a vault account the
program controls, state the program keeps, a transfer out when a condition holds) to v0.3.

## How to read this

Each claim carries where it comes from:

- **[measured]**: we ran it, on a local LEZ v0.3.0 chain (`infra/lez/localnet.sh`).
- **[from source]**: read in LEZ `v0.3.0` (`logos-blockchain/logos-execution-zone`) or in
  the swap repo at `cb0b112` (its latest commit, 2026-09-01), with the path given.
- **[inferred]**: our reasoning from the above. It has not been run.

## The HTLC today (LEZ v0.2.2)

The swap repo pins LEZ `v0.2.2` (`Cargo.toml`). Its LEZ program is
`programs/lez-htlc/methods/guest/src/main.rs` [from source]:

- **Lock** stores the escrow's terms in an account derived from the program and the
  hashlock (`for_public_pda(program, hashlock)`): the hashlock, maker, taker, amount,
  timelock and state. The client then funds it with a second transaction, an ordinary
  transfer (`src/lez/client.rs`, `lock`, "Two-step").
- **Claim** checks the taker's signature and `sha256(preimage) == hashlock`. It then
  moves the balance itself (`escrow.balance -= amount; taker.balance += amount`) and
  stores the preimage.
- **Refund** checks the maker's signature and moves the balance back. The timelock is a
  timestamp validity window on the program's output (`timelock..`).

The client already judges each step by reading the escrow back, never by the transaction
being accepted: the funding check after Lock and `refund_confirmed`. That instinct is
exactly right on v0.3 (§2).

## 1. Fees: the taker's first claim

**What changed.** These rules are from LEZ's source:

- **Every public transaction pays.** It declares a fee: payer, gas limit, tip and maximum
  fee, all inside the signed message. A public transaction with no fee is rejected at
  admission. The payer is authorized by an ordinary signature, so a fee payer must be an
  account that signs. A program-derived account like the escrow can't sign, so it can't
  pay. (`lee/state_machine/src/fees.rs`; `lez/sequencer/core/src/fees.rs`, `screen` and
  its test `a_transfer_without_a_fee_is_rejected`.) [from source]
- **The payer must hold the fee reserve to be admitted.** The reserve is
  `gas_limit × base_fee_exec + gas_stor × base_fee_stor + tip`. The execution base fee's
  floor is 8 (`lez/programs/fee/core/src/assess.rs`, `fee_reserve`;
  `lez/programs/fee/core/src/market.rs`). The LEZ wallet's default gas limit of 2,000,000
  therefore needs about 16M base units on hand. The unused part is refunded. [from source]
- **What we were actually charged.** A plain native transfer cost 2,968, and a co-paid
  one 3,864. [measured]
- **Private transactions pay nothing for now.** They carry no fee field ("fee-exempt
  under the interim policy"). [from source] But Lock, Claim and Refund are all public.
- **The faucet program is gone.** Native LEZ now arrives at genesis, over the bridge, or
  by a transfer from someone who holds some. [from source]

**What it does to the swap.**

- **The README's onboarding no longer holds.** It says "an empty LEZ balance is fine
  because LEZ charges no fees". A taker buying their first LEZ holds none, so the Claim
  that would pay them can't be admitted. [inferred]
- **Fixes that work.** [inferred]
  - **A fee float from the maker.** The maker sends the taker a small float, enough for
    one Claim's reserve, before or alongside Lock. The taker then claims and pays for
    themselves. A tight gas limit on Claim shrinks the float.
    - If the swap fails, the taker keeps the float. That's the maker's griefing cost.
    - The taker has already locked ETH and paid ETH gas first, which bounds the cost.
  - **The taker gets a little LEZ before the swap**, from anyone who holds some.
- **The fix that looks obvious, and its trap.** The obvious fix is for the maker to
  co-sign the taker's Claim as its fee payer.
  - **The danger.** The payer signs the message hash, and the message contains the
    preimage. If the taker sends the maker the claim message to co-sign, the maker can
    withhold the signature, claim the ETH with the preimage, and refund the LEZ after its
    timelock. The maker then keeps both assets. That's theft, not griefing. [inferred]
  - **The narrow way through.** The taker sends only the 32-byte hash. The payer can sign
    that without seeing the preimage, but then the payer is blind-signing a fee of up to
    the declared maximum. A third-party payer works the same way. It has less reason to
    steal, but the claim now depends on another party. [inferred]
- **What still holds.** After the first lock, a party can finish their claim or refund
  from local state and the two chains alone, with no Delivery. That still holds on v0.3,
  with one new condition: they hold enough native LEZ for their own fee reserve.
  - **The maker** has LEZ inventory, so this is only a budget. The funding check
    (`need >= amount`) should become amount plus the reserves for Lock and a possible
    Refund. [inferred]
  - **A first-time taker** is the gap.

## 2. A refused transaction is included, and pays

**What changed.** These are from LEZ's source:

- **A refused call is now included.** On v0.2.x the sequencer dropped a transaction its
  program refused. On v0.3 a "chargeable" failure is included:
  - its effects are discarded;
  - the fee is kept;
  - the signers' nonces are burned.

  (`lee/state_machine/src/validated_state_diff/mod.rs`: "A chargeable action failure keeps
  no effects but still advances the signers' nonces".) [from source]
- **A refusal is billed its whole gas limit.** A clean non-zero exit is billed only the
  cycles it ran. A panic, or a call outside its validity window, is billed the whole gas
  limit. Every refusal in the HTLC today is an `assert!`, so every refusal is a panic.
  An out-of-window call is chargeable (`lee/state_machine/src/error.rs`, the test asserting
  `OutOfValidityWindow.is_chargeable()`). [from source]
- **The sequencer reports no outcome.** `getTransaction` returns the transaction and its
  block, nothing more. Events live only in a separate indexer, and a reverted call emits
  none. [measured]
- **The cost in practice.** An outsider's refused vote cost 16,003,672 base units, where
  a member's accepted approval cost 456,112. A refused Execute cost 16,006,496.
  [measured]

**What it does to the swap.** [inferred]

- **A race at the timelock costs the loser.** The taker's Claim and the maker's Refund
  can race at the boundary. Whichever lands second is included, refused and billed its
  whole gas limit.
- **An early Refund is billed too.** A Refund sent before the chain's timestamp passes
  the timelock is refused and billed. Leave a margin, and judge time by the chain's block
  timestamp, not the local clock.
- **Declare a tight gas limit per instruction.** A refusal costs `gas_limit × base fee`.
- **Read the escrow before sending, and judge every step by its state afterward.** The
  client already does the second. Inclusion never means success on v0.3.
- **Re-read nonces before every send.** A failed transaction still advances them.
  `send_htlc_instruction` already fetches nonces on each send.

## 3. The program can't move balances any more

**What changed.** These are from LEZ's source:

- **An account is a set of shards**, one per program, and a program can change only its
  own. The native balance is the native token program's shard, 16 bytes little-endian
  (`lee/state_machine/core/src/account.rs`). [from source]
- **There's no `balance` field** for the HTLC to subtract from. Claim and Refund must
  call the native token program, `Transfer { amount }`, from the escrow.
- **The escrow is authorized by its seed.** Passing `pda_seeds = [hashlock]` on the
  chained call authorizes the native program to move `for_public_pda(P, hashlock)`,
  because the HTLC is the caller (`lee/state_machine/core/src/execution_state.rs`,
  `prepare_call`). [from source]

This is the same move our multisig's Execute makes to pay out of its vault, run end to
end on a local v0.3.0 chain. [measured]

## 4. The planning step can't read account data

**What changed.** A v0.3 program runs in two steps, `run_program(plan, apply)`
(`lee/state_machine/core/src/program/mod.rs`). [from source]

- **`plan`** sees the instruction and each account's id and authorization, but **no
  account data**. It emits:
  - effects, each aimed at one account's shard of one program;
  - chained calls;
  - events;
  - validity windows.
- **`apply`** runs once per effect, against that one shard's data, and returns its new
  data. A panic in any apply fails the whole transaction.

So a check that needs the escrow's stored terms happens in the escrow's `apply`. The
caller passes the terms in the instruction, and the escrow's `apply` refuses unless they
match what is stored.

**The hashlock-as-seed trick.** The escrow's address is derived from the hashlock, so
`plan` can tie a preimage to its escrow without reading anything: it checks that the
escrow row's id is `for_public_pda(P, sha256(preimage))`. [inferred]

**A sketch of the v0.3 HTLC.** [inferred] It follows the multisig port's pattern (the design note under
"Where our evidence lives"). `P` is the HTLC program's account id.

| instruction | `plan` checks | effect on the escrow's HTLC shard (`apply`) | chained call (native token program) |
|---|---|---|---|
| `Lock { hashlock, taker, amount, timelock }` | maker row authorized; maker ≠ taker; escrow row = `for_public_pda(P, hashlock)` | shard empty, then write `{hashlock, maker, taker, amount, timelock, Locked}` | `Transfer { amount }`, maker → escrow |
| `Claim { preimage, amount }` | preimage is 32 bytes; taker row authorized; escrow row = `for_public_pda(P, sha256(preimage))` | state is Locked; stored taker = the taker row; stored amount = `amount`. Then Claimed, preimage stored | `Transfer { amount }`, escrow → taker, `pda_seeds = [sha256(preimage)]` |
| `Refund { hashlock, amount, timelock }` | maker row authorized; escrow row = `for_public_pda(P, hashlock)`; timestamp window `timelock..` | state is Locked; stored maker, amount and timelock match. Then Refunded | `Transfer { amount }`, escrow → maker, `pda_seeds = [hashlock]` |

Notes on the table:

- **Refund's window.** `plan` can't read the stored timelock, so the caller supplies it,
  `plan` sets the window from it, and `apply` refuses unless it is the stored one. A
  caller who passes a smaller timelock to refund early is refused by `apply`.
- **Chained calls see only the transaction's own rows.** A chained call can select only
  accounts the transaction itself carries, so each transaction lists the transfer's
  accounts too. [measured, on the multisig]
- **The watcher reads the HTLC's shard.** It finds the preimage in the HTLC's shard of
  the escrow, not in `account.data`. An event would carry it too, but only through the
  indexer, and the shard read keeps "local state and the chains" true.

## 5. Lock can become one transaction

**What changed.** The swap's two-step Lock exists because v0.2.2's program couldn't move
the maker's funds.

- On v0.3, a transaction signer's public account stays authorized in every chained call
  the transaction makes (`execution_state.rs`, `authorize`, where the signer credential
  carries through). [from source]
- So Lock's `plan` can write the escrow's terms **and** chain `Transfer { amount }` from
  the maker in the same transaction. [inferred, not run]

**What it does to the swap.** This would remove the in-between state the watcher handles
today, "escrow exists but PDA balance is 0" (`src/lez/watcher.rs`). It would also remove
the client's funding poll.

## 6. Smaller changes

- **The program's id.** A v0.3 program is deployed through `program_loader`, in 96 KiB
  segments plus a header account, and the deployer pays. The program's account id is the
  header's id, chosen at deploy time, not the image id. Every escrow address derives from
  it. `swap-ffi/src/lez_htlc_program_id.rs` and `LezClient::escrow_pda` move with it.
  [measured]
- **Reading accounts.** `getAccount` returns `{nonce, data: {shards: {<program>: bytes}}}`.
  The escrow's terms are the HTLC's shard, and its balance is the native shard.
  [measured]
- **The public transaction message.** It is now `{program_account_id, shard_selectors,
  nonces, instruction_data (borsh bytes), fee}`, and the native token program is account
  0. [from source]
- **Gone with the faucet:** `src/lez/faucet.rs` (the pinata claim) and the "Get test LEZ
  without trading" path. [from source]
- **No account activation.** A fresh public account is claimed by its first funded
  transfer, so the Setup tab's "activate" step (`ensure_initialized`) has nothing left to
  do. [from source]

## Where our evidence lives

In this repo:

- [`docs/labbook/lez-v03-migration.md`](../labbook/lez-v03-migration.md): what v0.3 changed
  for us, with each trap and its fix. Traps 8–11 are the ones that bear on an escrow:
  refusals included and paid, chained-call rows, program deployment, account shards. It
  also has the fee and refusal numbers above.
- [`docs/design/lez-multisig-v03.md`](../design/lez-multisig-v03.md): the multisig
  redesigned for `plan`/`apply`, with the "each effect carries the claim the other shard
  checks" pattern this note's sketch borrows. It also covers the vault paying out by a
  chained call.

The port of `logos-co/lez-multisig` itself is not upstream yet.

## Not checked

- **Nothing here has run against the swap's own program.** The HTLC sketch (§4) and the
  one-transaction Lock (§5) are inferences from LEZ's source and from our multisig.
- **The fee figures are from a local chain** at its genesis base fee. The public testnet's
  base fee moves with load.
- **The ETH side is unchanged by LEZ v0.3**, and this note doesn't cover it.
