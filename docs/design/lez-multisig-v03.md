# The LEZ multisig on v0.3's plan/apply ABI (exo-eb6.4 L4)

Status: **design, 2026-10-01** (L4a, exo-6d9). The program comes next (L4b), then its
deployment on the local v0.3 zone (L4c), then muster (L4d), then upstream (L4e).

## 1. Why a redesign, not a port

LEZ v0.3.0 replaced the program ABI after 0.2.5-rc2 (`ee1ad8a3`, "replace the stateful program
ABI with account-local effects"). A v0.3 program is a pair, `run_program(plan, apply)`:

- **`plan(PlanInput, Instruction) → Plan`** sees the program's own account id, its caller, the
  instruction, and each row as an `AccountMeta { account_id, is_authorized,
  program_account_id }`. It sees **no account data**. It emits *effects*, each aimed at one
  `(account, program)` shard, plus chained calls, events and validity windows.
- **`apply(Effect, pre_data) → Option<ShardData>`** runs once per effect, against that one
  shard's current data, and returns its new data. It can replace only the program's own
  shards. A panic in any apply fails the whole transaction. Chained calls returned from
  an apply are refused (`721275b7`); they come from plan only.

So a check that needs data happens in `apply`, one shard at a time. A check that spans
accounts becomes **one effect per shard, each carrying the claim the other shard must
check** (`Plan::inspect` aims a guard at a shard without changing it). LEZ's own token
program works this way: the recipient's deposit sees the asset and amount, and the
sender's withdraw is what ties them to what the sender holds.

The published program (`logos-co/lez-multisig`, SPEL) generates code for the old stateful
ABI, and SPEL has no v0.3 support. SPEL PR #290 targets 0.2.5-rc2, which predates the
change. The operator's choice (2026-10-01) is a plain v0.3 program, like LEZ's own, offered
upstream as the v0.3 port.

## 2. Accounts and shards

`P` is the program's account id. On v0.3 it is the address of its deployment header
(`program_loader`), chosen at deploy time, not derived from the image id. Every PDA is
`AccountId::for_public_pda(P, seed)` = SHA-256(`"/LEE/v0.2/AccountId/PDA/"` padded ‖ P ‖
seed). That is muster's `psLee02` scheme unchanged, and the seeds stay SPEL's, so muster's
`statePda` / `proposalPda` / `vaultPda` keep their formulas:

| account | seed | shard used | holds |
|---|---|---|---|
| state | `create_key` | `(state, P)` | `MultisigState { create_key, threshold, members, member_count, next_proposal_index }` |
| proposal #i | SHA-256(`"multisig_prop___"` ‖ create_key ‖ i LE) | `(proposal, P)` | `Proposal` (§3) |
| vault | SHA-256(`"multisig_vault__"` ‖ create_key) | `(vault, 0)`, its native shard | native LEZ |
| a member | (their own key) | passed for authorization only | — |

Nothing is "claimed" any more. v0.2.4 had the program claim fresh member accounts, but a
v0.3 account is just its shards, so members need no setup and a funded account can be a
member.

## 3. What a proposal commits to

The target call becomes v0.3's shape:

```
Proposal {
  index, proposer, multisig_create_key,
  target: Option<TargetCall {
    program_account_id: [u8; 32],
    shard_selectors: Vec<(account_id, program_account_id)>,
    instruction_data: Vec<u8>,            // borsh, as v0.3 carries it
    pda_seeds: Vec<[u8; 32]>,             // the vault's seed, to authorize it to the callee
  }>,
  config_action: Option<ConfigAction>,    // exactly one of target / config_action
  approved: Vec<[u8; 32]>, rejected: Vec<[u8; 32]>, status,
}
```

`target_account_count`, `target_account_ids` and `authorized_indices` disappear. The
selectors name every account the call touches, so the recipient is committed by
construction (the #40 class of bug is gone). Authorization now comes from `pda_seeds`,
which authorize the callee to mutate `for_public_pda(P, seed)`, plus whatever signed the
transaction.

## 4. Each instruction as effects

Every instruction names the state and the proposal by their PDAs as rows. A signer appears
as a row whose `AccountMeta.is_authorized` is true, from the transaction's witness. Each
member pays their own fee (§6).

| instruction | plan asserts | effect on **state** (apply checks / changes) | effect on **proposal #i** (apply checks / changes) | chained call |
|---|---|---|---|---|
| `CreateMultisig { create_key, threshold, members }` | 1 ≤ threshold ≤ \|members\| ≤ 10, distinct | `Init(state)`: shard empty, then write it | — | — |
| `Propose { create_key, index, target }` | proposer row authorized | `Member(proposer)` + `TakeIndex(index)`: proposer ∈ members; index == next, then next += 1 | `Open(proposal)`: shard empty, then write it, `approved = [proposer]` | — |
| `ProposeConfig { create_key, index, action }` | likewise | likewise | likewise, with `config_action` | — |
| `Approve { create_key, index }` | voter authorized | `Member(voter)` (guard, keeps data) | `Vote(voter, yes)`: Active, then move voter into `approved` | — |
| `Reject { create_key, index }` | voter authorized | `Member(voter)` | `Vote(voter, no)`: Active, then into `rejected` | — |
| `Execute { create_key, index, approvers, call }` | — | `Quorum(approvers)`: distinct, each ∈ members, \|approvers\| ≥ threshold | `Close(approvers, hash(call))`: Active, each approver ∈ approved, stored target hashes to hash(call), then Executed | `call`, with the proposal's `pda_seeds` |
| `ExecuteConfig { create_key, index, approvers, action }` | — | `QuorumThenApply(approvers, action)`: the quorum check above, then apply the action (the add, remove and threshold rules of v0.2.4) | `Close(approvers, hash(action))` | — |

How Execute holds together:
- plan cannot read the proposal, so the executor supplies the call it read, and the
  approvers it counted.
- The proposal's apply refuses unless that call is the committed one and every approver
  really approved it.
- The state's apply refuses unless every approver is a **current** member and there are at
  least threshold of them.
- Both applies run in the one transaction, so the chained call runs only if both pass.

Counting only current members is deliberate. v0.2.4 counted every recorded approval,
including members removed since.

Reject leaves a proposal Active, as v0.2.4 did. One that can no longer reach threshold is
simply never executable, so it needs no state of its own.

## 5. The vault, and a transfer out of it

The vault holds native LEZ in its native shard. A transfer proposal's target is the native
token program:

- `program_account_id`: 0;
- shard selectors: `[(vault, 0), (to, 0)]`;
- instruction: borsh `Transfer { amount }`;
- `pda_seeds`: `[vault seed]`.

The chained call authorizes the native program to move the vault because its id is
`for_public_pda(P, vault seed)` and `P` is the caller. Anyone funds the vault by an
ordinary transfer to its id.

## 6. Fees

Each member's own transaction (Propose, Approve, Reject) is public, so it pays a fee. The
member is its own fee payer, as muster's member keys already sign their own transactions.
Execute is paid by whoever sends it. muster sends it from the settling member's own account,
and the vault pays nothing but the transfer. Create is paid by the creator.

## 7. What muster changes (L4d)

- **`lez/multisig.nim`**: the proposal's target becomes the v0.3 `TargetCall`; borsh for the
  new `Proposal` and the instructions (borsh now, not risc0 words); `P` is the configured
  program account id. The state layout is unchanged.
- **`FakeLezMultisig`**: the handlers above, as effects on shards, including Execute's two
  checks.
- **The live chain**: member transactions as `LezMessage3`, signed by keystore member keys,
  each member its own payer. Execute carries the approvers and the call read from the
  proposal (an S5 re-read).
- **The driver**: the pointer effect stays a pointer. The S5 re-read compares the v0.3
  target, and settlement builds Execute from the agreed call.
- **Vectors and tests**: vectors from the v0.3 program's own crate; `lez_multisig_live_e2e`
  on the local v0.3 zone; a substituted call refused by the chain; a removed member's
  approval not counted.

## 8. To check while building (L4b/L4c)

- That a row with no effect (a signer passed only for authorization) is accepted, and which
  program shard it should select.
- That a chained call from plan to the native program, with the vault seed, is authorized
  as §5 says.
- How `program_loader` deployment picks the header account, and how the program's account
  id is learned afterwards (the LEZ CLI, or `lez_core.send_program_deployment_transaction`).
- Whether a v0.3 guest builds without the docker image the v0.2.4 build pinned.
