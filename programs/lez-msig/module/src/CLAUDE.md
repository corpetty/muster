# programs/lez-msig/module/src/

`lez_msig_module`: lez-msig's private posture as a Logos module (RFP-005 U.1). Paths below are from
`programs/lez-msig/module/`.
- `src/lib.rs`: the generated `LezMsigModule` trait (`../generated/provider_gen.rs`, from
  `../lez_msig_module.lidl` by `../tools/regen.sh`), implemented over `msig_host::exec::exec_request`,
  the same function the `msig_exec` CLI runs.
- `src/jobs.rs`: one proof at a time, on its own thread. Each job is readable only by the caller
  that submitted it, and nothing is written to disk: the group secret lives in the job until its
  thread takes it, and the decrypted note in its answer until `forget`.
- `tests/module.rs`: the trait with no host; a live private Create as a job when `MSIG_LIVE_RPC` is set.
