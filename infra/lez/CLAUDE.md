# infra/lez/

`localnet.sh` builds and starts a local LEZ v0.2.4 standalone sequencer at
`127.0.0.1:3040`. That is the line the public testnet runs, and `localnet.sh stop` stops
it. Each start is a fresh chain, with 15s blocks and RISC0_DEV_MODE. The clone and build
live outside the repo, in `$MUSTER_LEZ_DIR` (default `~/.cache/muster/lez-v0.2.4`).

It is the chain for `module/tests/lez_multisig_live_e2e.nim` (exo-3c9). The test deploys
the multisig program when `MUSTER_LEZ_MULTISIG_BIN` names the guest binary. That binary is
built from logos-co/lez-multisig PR #45 or later, and its ImageID must be 2ced3d30…d4c7.

Rules:
- The sequencer is untrusted, user-configured infrastructure (invariant 8). Muster reaches
  it only through JSON-RPC (`wallet/lez_multisig_live.nim`).
- Keys stay in the TEST's keystores: member keys are keystore-derived, and nothing here
  holds one.
- Keep the chain fresh per run. The e2e uses random create keys and labels, so a reused
  chain also works, but a fresh one is the reproducible case.
- The build traps (libclang for RocksDB, r0vm on PATH for genesis) are in the script
  header and `docs/labbook/lez-multisig-versions.md`.
