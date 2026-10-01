# module/tests/vectors/lez-tx-v030/generator/src/

The vector generator for LEZ v0.3.0: a standalone Rust program, not part of the module
build. It prints `../../vectors.json` from LEZ v0.3.0's own crates (lee / lee_core / common),
so muster's v0.3 public-transaction encoder (`module/src/lez/tx.nim`) is held to the
chain's real bytes. How to run it and what each vector pins is in `../../SOURCE`.

Rules:
- Change it only to add vectors. Every existing vector stays byte-identical, because
  `lez_tx_test` pins them.
- Signatures use zero aux randomness, so they stay deterministic. Assert anything a vector
  claims, such as `WitnessSet::is_valid_for` and `is_fee_authorized`, before printing it.
- The v0.2.4 generator (`../../../lez-tx-v024/`) stays as it is: the v0.2.4 encoder is kept
  for the local v0.2.4 line until the LEZ multisig and FROST e2e tests move (exo-eb6.4).
