# lez04/host/tests/

`v04_state.rs`: the program on LEE v0.4 state, no sequencer. Create on a fresh PDA, pay 2 of 3, nothing before create, the account check, windows, a spend under a limit. Refusals matched by MsigError code.

`v04_private_fee.rs`: D17 on LEE v0.4 state, dev-mode proofs. The group's fee account (from the GMS, witnessed
`FeeOnly`) pays a private Create's fee; without its authorization key it cannot; the PDA cannot pay its own.

`v04_private.rs`: the private posture end to end, dev-mode proofs: the group's fee account topped up
from a public account (its first fee paid out of the credit), a private Create, a deposit
from a public account, a 2-of-3 payment to a public payee, every step's fee from the group's fee
account; below threshold and a spent nonce refused while proving.

`v04_private_payee.rs`: a private vault paying a PRIVATE payee: the credit sealed to its `Recipient`
and published, the payee's address nowhere in the transaction, only the payee opening it, the payee
claiming it in its own proof with the fee out of the credit.

`v04_private_call.rs`: a private Call: the native program at the vault's own balance (`rows[0]`), the
seed authorizing the vault inside the proof, a public payee credited; a target outside the allowlist
refused while proving.

`v04_undisclosed.rs`: D18. The program deployed through the loader (segments, then an immutable
header); a private Create proved undisclosed names no program and lands; a claim against a header the
zone never saw is refused.

`v04_gas.rs`: what every step meters (Create, Execute of a transfer or a config change, Queue,
ExecuteQueued, Spend; across members and approvals), as the sequencer meters it. `MSIG_GAS_OUT`
writes `module/tests/vectors/lez-msig/v04-gas.json`, which Muster's per-step gas limits are held to.

`live_public04.rs`: the same program against a real v0.4 standalone sequencer
(`MUSTER_LEZ_VERSION=v0.4.0-rc3 infra/lez/localnet.sh`, then `deploy`): create on a fresh PDA,
below threshold, a 2-of-3 payment, every transaction paying its fee. Skipped unless
`MSIG_LIVE_RPC` and `MSIG_LIVE_PROGRAM` are set. On a funded devnet: `MSIG_LIVE_FUND`,
`MSIG_LIVE_GAS` and `MSIG_LIVE_MAX_FEE` keep the payer's fees small (a refusal burns its whole
gas limit), `MSIG_LIVE_WAIT_S` waits out minute-long blocks, `MSIG_LIVE_CREATE_ONLY` stops after
Create. Passed on the 0.4.0-rc3 devnet, 2026-11-20 (`docs/labbook/lez-v04-port.md`).

`live_private04.rs`: the private posture against a real v0.4 sequencer: a fee-account top-up from a
public account, a private Create, a deposit, below threshold refused while proving, a 2-of-3 payment
to a public payee. Every fee in the proof, priced from `getFeeState` (`private_reserve`) and paid to
the zone's fee inbox; proved undisclosed (D18) when the program is immutable. Skipped unless
`MSIG_LIVE_RPC` and `MSIG_LIVE_PROGRAM` are set; `RISC0_DEV_MODE=1` only against a dev-mode zone.
Passed on a local 0.4.0-rc3 zone, 2026-11-20, and on the devnet with real proofs, 2026-11-21
(`CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true cargo test --release …`; labbook
`docs/labbook/lez-v04-port.md` trap 13).

`live_exec04.rs`: the executor's JSON surface against a real v0.4 sequencer, as Muster calls it:
derive, a top-up and a deposit signed outside the executor, Create, 1 of 2 answered `refused` with
its code, 2 of 3 paying a public payee, 2 of 3 paying a private payee (`recipients`) whose credit it
finds, opens and claims on chain, scan reading both newest notes back. Passed on a local
0.4.0-rc3 zone, 2026-11-21.
