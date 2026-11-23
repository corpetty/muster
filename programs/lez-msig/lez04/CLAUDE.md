# programs/lez-msig/lez04/

lez-msig on LEZ v0.4 (transactional actors), roadmap M3, exo-0d3.9. Its own cargo workspace:
LEZ v0.3 and v0.4 cannot share one dependency graph. The rules are the same `../core`
(`msig_core`), unchanged; only the adapter moves.

- `v04/`: `msig_v04`, the wire types and the account derivation (a private PDA has no identifier).
- `methods/`: embeds the deployed guest (`artifacts/msig.bin`) and its image id.
- `host/`: `msig_host04`, transactions for both postures, the executor (`exec.rs`) and the tests on
  LEE's own state (`V03State`, the type kept its name at v0.4.0-rc3).
- `module/`: `lez_msig_v04_module` 0.2.0 (lez_msig_module for LEZ v0.4, named apart so a host holds both), the executor as a Logos module (exo-cc7). This directory is its
  module package: `metadata.json`, `lez_msig_v04_module.lidl` (v0.3's contract plus `topup` and the fee
  account's notes), `generated/` (`tools/regen.sh`), `flake.nix` (`nix build .#lgx-portable`), which
  stages `../core` inside its source since the builder compiles only this directory.
- `artifacts/msig.bin`: the deployed v0.4 guest (the devnet's program, image id checked), embedded by
  `methods/build.rs`; `MSIG_BUILD_GUEST=1` rebuilds it.

Pins: LEZ `v0.4.0-rc3`. Both `Cargo.lock` files are seeded from LEZ rc3's own lockfile, because
risc0-zkvm 3.0.5 is yanked and a fresh resolve picks 3.1.0, which does not build with LEZ.
Build: `cargo test -p msig_host04` (the guest comes from `artifacts/`; `MSIG_BUILD_GUEST=1` rebuilds it with
rzup's toolchain). The private posture runs on LEE's state, on a local zone and on the devnet with real
proofs (exo-05f): fee-account top-up, Create, deposit, payment, every fee in the proof from the group's
fee account (D17), proved undisclosed (D18). Muster drives it through `msig_exec04`
(`lez_msig_private_e2e`), and through the real UI on the devnet (`scripts/lez-msig-private-self-test.sh`). A
private payee (sealed, claimed by it alone) and a private Call run on LEE's state; a private payee from the
room is exo-ea3.
