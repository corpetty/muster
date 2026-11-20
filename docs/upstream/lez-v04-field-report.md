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
  - a private Create;
  - a deposit from a public account into the private vault;
  - a 2-of-3 payment to a public payee (`custody_transfer` from the private PDA);
  - refusals below threshold and on a spent nonce.

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

### Latency [measured]

- The devnet made a block about once a minute, irregularly (local: every 15 s).
- Muster's seven-step room flow took about 25 minutes there; a local zone runs it in about 5.
- Proving a private step for real on 0.4 is not measured yet. On 0.3 the same payment proved in
  about 136 s + 15 s·M on a 64-core EPYC, 228 KB per transaction whatever M
  (`programs/lez-msig/BENCHMARKS.md`). We'll add 0.4's figures here.

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

### 2. A program-owned account cannot pay its own fee

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

### 6. Things that surprised us, documented here for other program authors

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
