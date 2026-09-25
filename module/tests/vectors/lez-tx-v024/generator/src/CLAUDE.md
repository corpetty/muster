# module/tests/vectors/lez-tx-v024/generator/src/

The vector generator: a standalone Rust program, not part of the module build. It prints
`../../vectors.json` from LEZ v0.2.4's own crates and lez-multisig's `multisig_core`, so
muster's LEZ transaction encoder (`module/src/lez/tx.nim`) is held to the chain's real
bytes. How to run it and what each vector pins is in `../../SOURCE`.

Rules:
- Change it only to add vectors. Every existing vector stays byte-identical, because
  `lez_tx_test` pins them.
- Signatures use zero aux randomness, so they stay deterministic. Assert anything a vector
  claims, such as `WitnessSet::is_valid_for`, before printing it.
