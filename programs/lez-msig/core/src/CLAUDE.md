# programs/lez-msig/core/src/

`msig_core`: the multisig's rules (`docs/design/lez-msig.md` §3–§5).
- `types.rs`: what is stored and signed (borsh). Variants are only ever appended (D19 added
  `Action::Rotate`, `Instruction::Sweep`), so no existing value's bytes change.
- `digest.rs`: the tagged hashes a signature covers.
- `rules.rs`: `claims` (from the instruction alone, for a plan) and `apply` (against the state, v0.3).
  An actor adapter (v0.4) calls `apply_stored` (a `Stored` shard: active, or retired by D19's
  rotation, which refuses all but `Sweep`), then `adopt` at the successor and `forward` on the
  balance's answer. v0.3's `apply` refuses `Rotate` and `Sweep` (`rotation-unsupported`).
- `error.rs`: every refusal, with a stable code.
- `sign.rs`: signing for hosts and tests (feature `signing`; a guest never signs).

`claims` and `apply` never panic. Signatures are checked last, so a cheap refusal costs no curve
arithmetic in the guest.
