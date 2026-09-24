# lez-multisig, nssa and LEE: three PDA schemes, one program binary (2026-09-24)

Context: Phase C (epic exo-a50.3) puts the vote locus on Logos's own chain through
`logos-co/lez-multisig`. Before building the live binding (exo-3c9), check which chain the
program can run on. The published program cannot run on the chain muster's `lez_core`
talks to.

## What is pinned where

| Thing | Pin | Chain core it speaks |
|---|---|---|
| `logos-co/lez-multisig` @ `c45100b` | `nssa_core` **v0.2.0-rc3**, `spel-framework` **v0.3.0** | nssa |
| muster's `lez_core` (runner) | `logos-execution-zone-module` @ `549cf11` (metadata 0.4.0) | LEZ **v0.2.2** |
| `lez_core` HEAD `825d2a4` (0.4.2) | LEZ **v0.2.5-rc2** | LEE, programs as accounts |
| testnet (`testnet.lez.logos.co`) | whatever `lez_core` 0.4.x targets | LEE v0.2.5 line |

## The PDA formula moved twice

Public PDAs are `SHA-256(prefix32 || program32 || seed32)` in every version, but the prefix
and the program's 32-byte identity changed:

| Version | Prefix | Program identity |
|---|---|---|
| nssa v0.2.0-rc3 (`nssa/core/src/program.rs`) | `/NSSA/v0.2/AccountId/PDA/` + 7 zero bytes | the image id (`[u32; 8]`) as LE bytes |
| LEZ v0.2.2 (`lee/state_machine/core/src/program/mod.rs`) | `/LEE/v0.2/AccountId/PDA/` + 8 zero bytes | the image id as LE bytes |
| LEE v0.2.5-rc2 (same file) | `/LEE/v0.2/AccountId/PDA/` + 8 zero bytes | the program's **account id** (programs are deployed as accounts) |

muster's `lez/multisig.nim` names the scheme on every account (`psNssa02`, `psLee02`).
`psLee02` covers both LEE versions, because the formula only takes 32 bytes; the config
says which program identity those bytes are.

## Why the program cannot just be deployed

The program's guest computes its own PDAs with the core it was compiled against (SPEL's
`compute_pda` calls `AccountId::for_public_pda` from its linked `nssa_core`). The chain
checks the accounts a transaction names against its own derivation. A guest built on
nssa rc3 therefore derives `/NSSA/...` addresses that a LEE chain will not match. The
program has to be rebuilt against the chain's core. That may be only a dependency bump
(SPEL is at v0.7.0), but it is an upstream change to `lez-multisig`, followed by a risc0
guest build (Docker) and a deployment (`send_program_deployment_transaction` in `lez_core`
0.4.2).

## What else the live binding needs

- `lez_core` **0.4.2** (bump from `549cf11`):
  - `send_generic_public_transaction(account_ids, signing_requirements, instruction,
    program_id, payer)`. The byte-string instruction IPC fix (`51eadfb`) and the `payer`
    argument (`0ea57f8`) are both after muster's pin.
  - `poll_transaction_status` (`aeb91ca`).
  - `get_account_public` for reading the state and proposal PDAs; the data is borsh.
- **Members must be fresh.** `CreateMultisig` requires every member account to be
  `Account::default()` (never used) and claims it for the program. A member's vote fee is
  therefore paid by a separate funded account of theirs (the `payer`). The in-process
  model enforces the same rule.
- **Instruction encoding.** The program's `Instruction` is a serde enum, so the
  instruction words follow the risc0 serde encoding. Pin this against a real sequencer
  before trusting it.
- **A local chain is possible on this box.** `logos-scaffold` (`lgs setup`) builds a LEZ
  v0.2.2 localnet (see `atomic-swaps-toolchain-on-fedora.md`), which is enough once the
  program is rebuilt for that core.

Until then, Phase C runs against `FakeLezMultisig` (`lez/multisig_chain.nim`), which
reproduces the handlers of `c45100b` with their own messages, over borsh accounts.
