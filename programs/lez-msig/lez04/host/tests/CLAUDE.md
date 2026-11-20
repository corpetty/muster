# lez04/host/tests/

`v04_state.rs`: the program on LEE v0.4 state, no sequencer. Create on a fresh PDA, pay 2 of 3, nothing before create, the account check, windows, a spend under a limit. Refusals matched by MsigError code.

`live_public04.rs`: the same program against a real v0.4 standalone sequencer
(`MUSTER_LEZ_VERSION=v0.4.0-rc3 infra/lez/localnet.sh`, then `deploy`): create on a fresh PDA,
below threshold, a 2-of-3 payment, every transaction paying its fee. Skipped unless
`MSIG_LIVE_RPC` and `MSIG_LIVE_PROGRAM` are set.
