# lez04/host/tests/

`v04_state.rs`: the program on LEE v0.4 state, no sequencer. Create on a fresh PDA, pay 2 of 3, nothing before create, the account check, windows, a spend under a limit. Refusals matched by MsigError code.

`v04_private_fee.rs`: D17 on LEE v0.4 state, dev-mode proofs. The group's fee account (from the GMS, witnessed
`FeeOnly`) pays a private Create's fee; without its authorization key it cannot; the PDA cannot pay its own.

`v04_private.rs`: the private posture end to end, dev-mode proofs: a private Create, a deposit
from a public account, a 2-of-3 payment to a public payee, every step's fee from the group's fee
account; below threshold and a spent nonce refused while proving.

`v04_bench.rs` (ignored): the same steps with REAL proving for M = 1, 3, 5, 10 (RFP P.1/P.2);
`cargo test --release -p msig_host04 --test v04_bench -- --ignored --nocapture`.

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
