# programs/lez-msig/

An M-of-N multisig program for LEZ, private by default (epic exo-0d3, RFP-005). The design and
its decision log are `docs/design/lez-msig.md`; read it before changing a rule.

- `core/`: `msig_core`, the rules as two pure functions, with no LEZ dependency. Every rule lives
  here and is tested here.
- `v03/`: `msig_v03`, the LEZ v0.3 wire types and the multisig's account derivation, shared by
  the guest and the host.
- `methods/`: embeds the deployed guest (`artifacts/msig.bin`) as `MSIG_ELF` and its image id as
  `MSIG_ID`; `MSIG_BUILD_GUEST=1` rebuilds `methods/guest` with risc0-build instead.
- `host/`: `msig_host`, the client, and the tests on LEE's own state machine.
- `artifacts/`: `msig.bin`, the deployed v0.3 guest. Its image id is the program's identity.
- `module/`: `lez_msig_module`, the private posture as a Logos module (RFP U.1), over the same
  executor as the `msig_exec` CLI. `generated/` holds its provider trait, and `tools/regen.sh`
  regenerates it from `lez_msig_module.lidl`.
- `lez04/`: lez-msig on LEZ v0.4, its own cargo workspace over the same `core/`; shipped in
  Muster 0.4.0 with `lez_msig_v04_module` (`lez04/CLAUDE.md`).

Rules:
- A rule belongs in `msig_core`. An adapter only maps it onto a runtime: v0.3's plan/apply
  (`v03/`) and v0.4's actors (`lez04/`, exo-1e7, closed). If an adapter starts deciding, move the
  decision to the core.
- Signing payloads are tagged hashes over borsh (`core/src/digest.rs`). Changing a tag, a field,
  or a field's order changes every signature: bump the `v1` in the tags and say so in the design.
- The program is granted only the multisig's own seed. The plan re-derives the account from the
  placement and refuses any other row. Never pass a seed from the instruction (exo-325).
- Every refusal is an `MsigError`, with a stable code first in its message (RFP U.7).
- Benchmarks use real proving (no `RISC0_DEV_MODE`), or they are not reported (RFP P.1).
- Build: `cargo build -p msig_methods` and `cargo test`. The guest comes from `artifacts/`;
  `MSIG_BUILD_GUEST=1` rebuilds it (~3 min the first time) with rzup's risc0 toolchain, and that
  build must then be deployed and committed. The toolchain is LEZ v0.3.0's (1.98.1).
