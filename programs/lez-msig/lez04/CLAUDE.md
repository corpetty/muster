# programs/lez-msig/lez04/

lez-msig on LEZ v0.4 (transactional actors), roadmap M3, exo-0d3.9. Its own cargo workspace:
LEZ v0.3 and v0.4 cannot share one dependency graph. The rules are the same `../core`
(`msig_core`), unchanged; only the adapter moves.

- `v04/`: `msig_v04`, the wire types and the account derivation (a private PDA has no identifier).
- `methods/`: builds the guest (`methods/guest`) with risc0-build; no deployed artifact yet.
- `host/`: `msig_host04`, public transactions and the tests on LEE's own state (`V03State`, the
  type kept its name at v0.4.0-rc3).

Pins: LEZ `v0.4.0-rc3`. Both `Cargo.lock` files are seeded from LEZ rc3's own lockfile, because
risc0-zkvm 3.0.5 is yanked and a fresh resolve picks 3.1.0, which does not build with LEZ.
Build: `cargo build -p msig_methods04` (the guest, rzup's toolchain), `cargo test -p msig_host04`.
The private posture on v0.4 runs on LEE's state (exo-05f, `host/tests/v04_private.rs`): Create, deposit and
payment, each fee paid in the proof by the group's fee account (D17). D18's undisclosed image is shown (`v04_undisclosed.rs`).
Not yet: a private payee, a call, the prover module and a live zone.
