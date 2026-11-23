# Field report: an M-of-N multisig on LEZ 0.4.0-rc3

**To:** the LEZ team (`logos-blockchain/logos-execution-zone`).
**From:** the Muster team (`corpetty/muster`), building RFP-005's multisig (`lez-msig`).
**Date:** 2026-11-20. **Status:** notes and asks, kept current as we go. Nothing here is built on
your side.

## One line

lez-msig runs on 0.4.0-rc3: on your devnet, from Muster's room, every step paying its own fee. The
things that cost us most:
- a refused transaction burns its whole declared gas limit;
- the sequencer cannot estimate one;
- a program-owned account cannot pay its own fee.

Below: what we ran, what it cost, and what would help.

## How to read this

- **[measured]**: we ran it, on the 0.4.0-rc3 devnet (`46.225.45.199:3040`) or a local
  0.4.0-rc3 standalone sequencer, or on LEE's own state machine (`V03State`).
- **[from source]**: read in LEZ `v0.4.0-rc3`, with the path given.
- **[inferred]**: our reasoning from the above; not run.

## What we ran

lez-msig is an M-of-N vault. The program holds the config (members, threshold, time lock, spending
limits) at a PDA and verifies the members' BIP-340 approvals itself. It comes in two postures:
- **public:** the state lives at a public PDA;
- **private:** a group-owned private PDA, keys derived from a group secret (GMS).

Its 0.4 port is one actor handler (`actor_entrypoint!`); the payout is
`custody_transfer(A, seed, to, amount)`.
- **Devnet, public posture** [measured]. The program is deployed immutable at
  `2tTh5nUpBxtTAoQBCQbzmG32JGapm2KaEpH9oxktGanG`; the deploy cost about 8.6M. Our standalone
  test (`programs/lez-msig/lez04/host/tests/live_public04.rs`) passed:
  - a Create on a fresh PDA;
  - a refusal below threshold;
  - a 2-of-3 payment.

  Muster's three-member room flow (`module/tests/lez_msig_live_e2e.nim`) passed 7/7: Create, a
  2-of-3 payment, approvals refused after a config change, a queued time-locked payment, nothing
  sent below threshold, and a second multisig over a member's own account.
- **Private posture, in-process** [measured, dev-mode proofs], every step's fee paid in the proof
  by a GMS-derived regular account witnessed `RegularKey::FeeOnly`
  (`lez04/host/tests/v04_private.rs`, `v04_private_fee.rs`):
  - a top-up of the group's fee account from a public account, the fee account paying that
    transaction's own fee out of the credit, so a group starts with no funds;
  - a private Create;
  - a deposit from a public account into the private vault;
  - a 2-of-3 payment to a public payee (`custody_transfer` from the private PDA);
  - refusals below threshold and on a spent nonce.
- **Private posture through Muster's real UI, devnet** [measured, real proofs, 2026-11-21]: two
  runners in one room, the prover a Logos module in each. A private 2-of-2 was opened, its fee
  account topped up, created, funded, and a payment approved and settled, in 925 s end to end,
  about four proofs and a dozen minute-long blocks (`scripts/lez-msig-private-self-test.sh`).
- **Private posture, devnet** [measured, real proofs, 2026-11-21]: the same four steps against the
  devnet (`lez04/host/tests/live_private04.rs`), all accepted: proved in 104 s, 257 s, 233 s and
  292 s, about 230 KB each. That build ran with debug assertions on (below), about 38% slower than
  our benchmark's figures. The same test passed on a local zone first, with dev-mode receipts. Each fee went to the zone's fee
  inbox, priced from `getFeeState`, and the program was deployed immutable so every proof named no
  program (D18).

## Performance

### What each step meters [measured]

On LEE's state, by `ValidatedStateDiff::from_public_transaction_with_cycle_budget`: the cycles the
sequencer charges. The guest uses RISC Zero's accelerated `k256`, `sha2` and `crypto-bigint`.
Full table: `module/tests/vectors/lez-msig/v04-gas.json` (70 rows, N up to 10 members, M up to 10
approvals).

| step | cycles |
|---|---|
| Create, N members | ≈ 14k + 30k·N (3 members: 103,635) |
| Execute a payment, M approvals | ≈ 30k + 275k·M (2 of 3: 580,795; 10 of 10: 2,780,380) |
| Execute a config change | the payment's cost + ≈ 29k·N |
| Queue (time lock) | the same as Execute |
| ExecuteQueued | ≈ 28k–37k (no signatures) |
| Spend under a limit, M signers | the same as Execute |

**One BIP-340 verification costs about 275k cycles**, even accelerated. It is nearly the whole cost
of any M-of-N step. Cycles vary by about ±1k with the keys.

### What it costs [measured]

At base fee 8 (execution and storage), where the fee is cycles × base fee plus wire bytes × base
fee:

| transaction | paid |
|---|---|
| Create (2-of-3), 103,635 cycles + 660 bytes | 834,360 |
| Execute 2-of-3, a payment | 4,657,224 local; 4,687,312 devnet |
| Execute refused below threshold, 700k gas limit | 5,606,640: (700,000 + 830) × 8 |
| Execute refused below threshold, 4M gas limit | 32,006,640 |
| Deploying the program (immutable) | about 8.6M |
| Any private transaction, at the next block's ceiling of 9 | 5,704,443 reserved (5,070,616 at the head) |

A private transaction's fee is flat [from source, `lez/programs/fee/core/src/assess.rs`]:
`(PRIVATE_VERIFY_GAS + public cycles) × exec + PRIVATE_GAS_STOR × stor`. That is 409,764 gas for
verifying the receipt plus 224,063 bytes of proof and padding, about 5.07M at base fee 8 whatever
the program does inside the proof. So the private posture's 2-of-3 payment costs about what the
public one does (4.66M), but its fee no longer grows with M: the approvals are verified inside the
proof.

### Latency [measured]

- The devnet made a block about once a minute, irregularly (local: every 15 s).
- Muster's seven-step room flow took about 25 minutes there; a local zone runs it in about 5.
- **Real proving of a private step** on 0.4, local CPU prover, AMD EPYC 7C13 (64 cores), peak
  memory 9.6 GB (`programs/lez-msig/BENCHMARKS.md`, `lez04/host/src/bin/msig_bench04.rs`):

  | step | 0.4 (s) | 0.3 (s) |
  |---|---|---|
  | public → one private account (fee-account top-up) | 75 | (none) |
  | public → the vault, plus the fee witness (deposit) | 169 | 77 (no fee) |
  | create (3 / 10 members) | 184 / 192 | 110 / 117 |
  | pay with M = 1 / 3 / 5 / 10 approvals | 195 / 209 / 235 / 298 | 126 / 144 / 171 / 232 |

  The 0.3 column is the idle run on the same machine (2026-11-19).
  - A payment proves in about 182 s + 11.5 s·M (0.3: 111 s + 12.0 s·M): about 70 s more at the
    base, the same per approval.
  - **The in-proof fee costs about 95 s on every step**: the deposit and the top-up are the same
    transfer, and the deposit's extra private account, the fee witness, is the difference.
  - Transactions are 229–238 KB, flat in M (0.3: 228 KB).

## What worked as designed

- **`RegularKey::FeeOnly`** [measured]: a group's shared fee account pays the fee and is authorized
  for nothing else.
- **Undisclosed program claims** [measured, `lez04/host/tests/v04_undisclosed.rs`]: with the program
  deployed immutable through the loader and `ProgramCatalog::with_undisclosed`, a private execution's
  only claim is a commitment-set root. The program's account appears nowhere in the transaction's
  bytes, and the zone accepts it. A default proof names the program. A claim against a header the
  zone never saw is refused. This keeps the property 0.3 gave us for free; a sentence in the
  program-author docs saying that private programs should deploy immutable would make it the
  default rather than a discovery.
- **Private PDAs and `custody_transfer`** [measured]: the same guest serves both postures unchanged.

## What we hit, and what would help

### 1. A refusal burns the whole gas limit, and nothing can estimate one

**What happens** [measured]:
- A transaction the program refuses is included and charged its whole declared gas limit, not the
  cycles it used.
- The sequencer refuses a `max_fee` below the reserve: "max_fee 400000 below the fee reserve
  8005280" for a 1M limit.

**Why it bites** [from source]:
- The wallet's default limit is 2M (`lez/wallet/src/lib.rs`, `DEFAULT_GAS_LIMIT`), so a client
  that keeps it pays about 16M per refusal.
- The wallet avoids this by simulating locally, running the program
  (`simulate_privacy_preserving_transaction`, `simulate_public_transaction`). A client that cannot
  run the program has nothing to ask: the sequencer's RPC has `getFeeState` but no simulate or
  estimate method (`lez/sequencer/service/rpc/src/lib.rs`). Muster's backend is Nim, so it is in
  that position.

**What we did:** measured every step's cycles and derived a per-step limit from them
(`module/src/lez/msig_gas.nim`). The worst over-declaration is 2.2×, on the cheapest step. That is
workable, but it needs every program author to re-measure after any change.

**Asks:**
- A `simulateTransaction` (or `estimateGas`) RPC that runs a public transaction against head state
  and returns its cycles and whether it reverts. The wallet already has the function.
- Or, to consider: charge a chargeable revert by the cycles it used, as success is, rather than by
  its limit. We understand the limit-burn may be deliberate anti-spam; if so, documenting it for
  program authors would help.

### 2. A program-owned account cannot pay its own fee, and the workaround costs proving time

**What happens** [measured, `v04_private_fee.rs`]:
- A private transaction pays its fee inside the proof, from a regular private account whose
  witness holds its authorization key.
- A private PDA cannot be that payer. Neither can a regular account witnessed with only its
  nullifier key: that is refused with `FeePayerWithoutAuthorization`.
- `RegularKey::FeeOnly` works well for what we needed. It authorizes the fee entry alone.

**Consequences:**
- Every multisig needs a second, separately funded fee account beside its vault.
- We derive it from the group secret with `derive_regular_shared_account_keys`, so every member
  can use it. But anyone holding that secret, a removed member included, can drain it [inferred].
- The vault itself, the one account the group already funds and controls, can never pay.

- **It costs proving time** [measured]: the fee account is a second private account in every proof,
  about 95 s of a 170–300 s step on a 64-core machine.

**Ask, for discussion:** a way for a program to authorize its own PDA as a transaction's fee payer
under the same rules that let it spend (a fee entry the program's handler approves). Group-owned
vaults could then be self-sufficient. We have not thought through the anti-spam side.

### 3. No way to ask a zone which line it runs

**What happens** [measured]:
- We pointed LEZ's 0.3.0 wallet CLI at a 0.4 zone by mistake. Its deploy failed on the first
  segment: "invalid type: null, expected struct Account". That is the 0.3 client reading 0.4's
  `null` for a fresh account.
- Muster detects the line from the shape of a `getAccount` answer: shards on 0.3, actor states on
  0.4.

**Ask:** a version, or protocol-line, field from `checkHealth` or a new `getVersion`, so clients
fail with "this zone runs 0.4" instead of a parse error. The wallet could check it on startup.

### 4. Deploys don't resume

**What happens** [from source]: `upload_segments_and_header` carries
`// FIXME: Resume after a partial upload; retrying the same segments currently fails`
(`lez/wallet/src/program_facades/program_loader.rs`).

**Why it bites** [inferred]: on a devnet with minute-long blocks, an interrupted deploy strands
paid segments, and a retry has to start over with fresh accounts.

**Ask:** resumable uploads, or a note in the CLI's error that names the stranded accounts.

### 5. A note's commitment is not in its own action

**What happens** [measured, `lez04/host/tests/v04_private.rs`]:
- A member reads their new note by decrypting `encrypted_post_state` under the action's nullifier.
- With one private action, the decrypted account's commitment equals that action's `commitment`.
- With two (any private step that pays its fee in the proof: the PDA plus the fee account), it
  does not: the commitment sits in the other action.

`PrivateAction` does warn that the commitment "is not necessarily connected to the nullifier in
content" [from source, `lee/state_machine/core/src/circuit_io.rs`]. But every scanner written
against 0.3's single-action transactions matched within the action, and on 0.4 they fail silently:
the note just isn't found. We now match the decrypted account against every commitment the
transaction makes.

**Ask:** say so in the scanning docs, or give each note an index to its commitment. Wallets and
indexers outside your workspace will hit this the first time a fee shares a proof.

### 6. Private fee pricing has two cliffs a client has to know about

**What happens** [from source, `lez/programs/fee/core/src/market.rs`]:
- A reserve's surplus over the fee up to `MIN_PRIVATE_REFUND` (1,000,000) is kept as tip. A larger
  one comes back as a refund publication, which the payer has to find and claim in a later proof.
  So a client sizing its reserve generously pays for that with an extra claim step. We price at the
  next block's ceiling, whose surplus at base fee 8 is about 634k, under the floor
  (`msig_host04::private_reserve`).
- A private transaction carries at most `MAX_PRIVATE_ACTIONS` (8) private actions. A multisig step
  uses two (the vault and the fee account), so this doesn't bind us yet. A private payee, a call
  with private rows, or claims of pending deposits each add actions, so it bounds what one step can
  do.
- `PRIVATE_VERIFY_GAS` and `PROOF_BYTES` are marked provisional (`FIXME: re-pin`).

**Ask:** expose the private fee and the refund floor through `getFeeState`, so clients that
cannot link `fee_core` (ours is Nim) need not copy the constants, and say when they will be
re-pinned.

### 7. A private payment below the private fee cannot be claimed from itself

**What happens** [measured, `lez04/host/tests/live_exec04.rs`, local 0.4.0-rc3 zone]:
- lez-msig pays a private payee by an async message sealed to its `Recipient`, and that works well.
  The proof never names the payee, and only the payee's keys open the published message.
- The payee then claims it in a private transaction of its own, which pays the flat private fee:
  5,704,443 reserved at base fee 8–9.
- So a payee with no other funded private account can only claim a payment larger than that fee.
  A smaller one is stuck until the payee funds a private account some other way.

**Ask, for discussion:** a cheaper claim (a claim's proof verifies one message and makes one note),
or a way for the sender to pay the receiver's claim fee in the sending proof. Payroll, refunds and
other small private payments from a vault all hit this.

### 8. Receiving into a private vault from a public account

**What works** [measured, `v04_private_inbound.rs`, `live_exec04.rs` on a local zone]:
- The vault's Create registers its recovery binding.
- Anyone can then pay the vault's address from a public account. The zone publishes the credit in
  the clear, and the group recovers it with its keys and collects it inside its next private
  transaction (`ProvingInput.claims`), once only.
- Without the binding, the payment is refused (`UnboundAsyncDestination`).

**What we hit:**
- **The wallet CLI cannot make that payment** [measured]. `auth-transfer send --to` declares the
  destination public, so the transaction reverts ("declared public but not admitted"). For an
  unowned private account the CLI wants `--to-npk`/`--to-vpk` and sends a sealed private transfer,
  which needs the payer to hold private funds. We built the public transaction ourselves.
- **Finding deposits means reading every publication** [from source]: `getPublications` pages by
  position only, so a vault's client walks the whole stream, and remembers which ones it collected.

**Asks:**
- A wallet option to pay a bound private address from a public account (leave the destination
  undeclared).
- `getPublications` filtered by destination address for clear publications. Their addresses are
  already public, so the filter discloses nothing new.

### 9. A test cannot prove at release speed

`test-utils` refuses to compile in a release build [from source, `lee/state_machine/src/lib.rs`],
and a crate's tests get it whenever they use LEE's test helpers through dev-dependencies. So an
integration test that proves for real either runs unoptimized (far slower) or sets
`CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true`, which your own comment notes slips past the check,
at about 38% slower proving [measured]. We moved our benchmark into a binary to avoid it.

**Ask:** split the state-mutation helpers from the harmless ones (`TestPrivateKeys`,
`signer_nonces`), so a release test can use the latter.

### 10. Things that surprised us, documented here for other program authors

- **A fresh public account must be admitted by its key** [measured]: funding one takes
  `--to-pk`. A program's own fresh PDA needs `PublicAccountEvidence::Pda` on Create.
- **A payee no one has used must be left undeclared**, or the whole transaction is refused
  ("declared public but not admitted"). Its credit then waits as a pending message it claims
  [measured]. The wallet does the same. A line in the program-author docs would have saved us a
  day.
- **`getAccount` answers `null` for an account no one has used** (0.3 answered a default account)
  [measured].
- **The public message hash is still domain-separated `/LEE/v0.3/Message/Public/`** on 0.4
  [from source]. That is harmless, but we checked it twice.
- **`risc0-zkvm` 3.0.5 is yanked** [measured]. A fresh `cargo` resolve picks 3.1.0, which does not
  build with LEZ (`risc0-zkos-v1compat`). We seed lockfiles from LEZ's own. A published lockfile
  or template for program authors, or a move to an unyanked release, would help everyone outside
  your workspace.

## Reproduce

- **The cycle table:** in `programs/lez-msig/lez04`, run
  `MSIG_GAS_OUT=<path> cargo test -p msig_host04 --test v04_gas` (about 3 min, no prover).
- **Devnet:** `docs/labbook/lez-v04-port.md`, traps 9–12, has every command, including Muster's
  room flow.
- **Private fees:** `RISC0_DEV_MODE=1 cargo test -p msig_host04 --test v04_private_fee`.
