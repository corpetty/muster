# programs/lez-msig/host/src/bin/

- `msig_bench`: proves create, fund and an M-signature payment privately, M = 1 3 5 10 by default.
  It prints the host and the times; run it on an idle machine.
- `msig_vectors`: prints the vectors JSON for `module/tests/vectors/lez-msig/vectors.json`. Regenerate
  it when a tag, a type or an encoding changes, and rerun `lez_msig_bytes_test`.
- `msig_exec`: the private posture's executor. One JSON request on stdin, one JSON answer on stdout:
  `derive` (the private PDA from the group secret), `exec` (prove and send one instruction over the
  multisig's current note; it answers with the new note), and `fund` (a development-only shield
  from a key passed in). Muster builds and signs everything else; this exists because proving needs
  LEZ's Rust prover. The Logos module `lez_msig_module` (`../../../module/`, RFP U.1) runs the same
  `exec_request`; `msig_exec` stays as its CLI, for tests (`lez_msig_private_e2e`).
