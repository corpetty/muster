# programs/lez-msig/host/tests/

`v03_state.rs`: the program on LEE's own `V03State`, with no sequencer. It covers the public posture
end to end, the plan's account and row checks, windows, R.2, a spending limit, and the private posture
with dev-mode receipts. Refusals are matched by their `MsigError` code.

`live_private.rs`: the private posture against a real sequencer, with the loader-deployed program.
It creates, shields into, and pays 2-of-3 out of a group-owned private PDA. It is skipped unless
`MSIG_LIVE_RPC` and `MSIG_LIVE_PROGRAM` name a zone; it funds a throwaway key through
`infra/lez/funder.sh`.

`live_public.rs`: the public posture through `msig_host::public` only, an integrator's journey with no
Muster (RFP-005 U.1): prepare + send_public a Create, propose, check, execute, add a limit and spend
under it, every key and signature outside. Skipped unless the same two variables are set.
