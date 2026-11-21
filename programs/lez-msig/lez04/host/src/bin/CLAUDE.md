# lez04/host/src/bin/

`msig_vectors04.rs`: ground truth for muster's Nim port of LEZ v0.4.0-rc3 public transactions (`module/src/lez/tx.nim` `LezMessage4`), from LEZ's own crates; its output is `module/tests/vectors/lez-msig/v04.json`.

`msig_bench04.rs`: RFP P.1/P.2 on v0.4, REAL proving only (refuses `RISC0_DEV_MODE`): for each M, a
fee-account top-up, a private Create, a deposit and an M-signature payment, every fee in the proof.
`cargo run --release -p msig_host04 --bin msig_bench04 -- 1 3 5 10`. A binary because LEE refuses its
test-utils in a release build, and the tests' dev-dependencies enable them.

`msig_exec04.rs`: `exec::exec_request` as a CLI, one JSON request on stdin, one answer on stdout;
Muster's `CliMsigProver` runs it against a v0.4 zone.
