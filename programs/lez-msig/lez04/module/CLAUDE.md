# lez04/module/

`lez_msig_v04_module` 0.2.0 (lez_msig_module for LEZ v0.4, named apart so a host holds both): lez-msig's private posture on LEZ v0.4 as a Logos module (exo-cc7). The same
crate as `../../module` (v0.3, 0.1.0) over `msig_host04::exec::exec_request` instead, plus `topup`.
- `src/lib.rs`: the generated `LezMsigModule` trait (`../generated/provider_gen.rs`), implemented over
  the executor; `health` reports `line: "v0.4"`.
- `src/jobs.rs`: one proof at a time, on its own thread, each job readable only by its caller; nothing
  on disk.
- `tests/module.rs`: the trait with no host; a fee-account top-up as a job when `MSIG_LIVE_RPC` is set.
