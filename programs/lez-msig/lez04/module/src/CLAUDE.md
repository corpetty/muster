# lez04/module/src/

`lib.rs`: `LezMsigModuleImpl`, the generated trait over `msig_host04::exec::exec_request`; `exec`, `fund`,
`topup` and `scan` run as jobs, `derive` and `send` at once. `jobs.rs`: the job table, one proof at a
time on its own thread, each job readable only by the caller that submitted it, nothing on disk.
