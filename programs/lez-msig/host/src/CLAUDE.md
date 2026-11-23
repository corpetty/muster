# programs/lez-msig/host/src/

`msig_host`: the client on LEZ v0.3.
- `lib.rs`: `Msig`, one multisig at its placement (a public PDA, or a private PDA whose keys come
  from the group's master secret). It builds rows and envelopes from the core instruction, so host
  and guest agree by construction. It builds public and privacy-preserving transactions, and
  decrypts the multisig's new note.
- `exec.rs`: `exec_request(json) -> json`, the private posture's executor (derive / exec / fund).
  `bin/msig_exec` and the Logos module `lez_msig_module` both call it.
- `bin/msig_bench.rs`: RFP P.1/P.2 with real proving (it refuses `RISC0_DEV_MODE`).
- `bin/msig_vectors.rs`: ground truth for muster's Nim port (`module/tests/vectors/lez-msig`).
- `public.rs`: the public posture's key-free operations (state, propose, spend, check, prepare,
  send_public) for integrators without Muster; `exec_request` routes them, so `msig_exec` and the
  Logos module carry them too (`docs/design/lez-msig-signing.md`).
