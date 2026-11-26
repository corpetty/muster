# module/tests/vectors/lez-msig/

`vectors.json`: lez-msig's bytes from the program's own host (`programs/lez-msig/host/src/bin/msig_vectors.rs`),
for `lez_msig_bytes_test`. Never edit by hand; regenerate with `cargo run -p msig_host --bin msig_vectors`.

The LEZ v0.4 files come from `programs/lez-msig/lez04` (run there, never edited by hand):
- `v04.json`: v0.4.0-rc3 public transactions from LEZ's own crates, for `lez_v04_tx_test`
  (`cargo run -p msig_host04 --bin msig_vectors04`).
- `v04-recipients.json`: a private payee as borsh and the address it derives, for
  `lez_msig_recipient_test` (`cargo run -p msig_host04 --bin msig_recipient_vectors04`).
- `v04-gas.json`: the gas each lez-msig step used on LEE's state, for `msig_gas_test`
  (`MSIG_GAS_OUT=… cargo test -p msig_host04 --test v04_gas`).
