# infra/lez/

`localnet.sh` builds and starts a local LEZ standalone sequencer at `127.0.0.1:3040`. By
default it runs v0.3.0, the line the public testnet runs since 2026-09-30 (exo-eb6.4);
`MUSTER_LEZ_VERSION=v0.2.4` runs the old one. Each start is a fresh chain, with 15s blocks
and RISC0_DEV_MODE. `localnet.sh stop` stops it. The clone and build live outside the
repo, in `$MUSTER_LEZ_DIR` (default `~/.cache/muster/lez-<version>`).

On v0.3.0 there is no faucet. The script keeps a **funder**: a wallet of LEZ's own CLI
(`wallet`, in `$MUSTER_LEZ_DIR/.muster-funder`) whose public account is the one genesis
supply account the script writes. `localnet.sh fund <account> <amount>` sends from it, as a
person holding native LEZ would. `scripts/lez-local-self-test.sh` is the check: a runner's
real lez_core wallet on this zone (`MUSTER_LEZ_RPC`), funded by the funder, reads its
balance back.

The v0.2.4 line is the chain for `module/tests/lez_multisig_live_e2e.nim` (exo-3c9) and the
LEZ FROST e2e tests, until they move to v0.3 (exo-b87, exo-9ed). The multisig test deploys
the program when `MUSTER_LEZ_MULTISIG_BIN` names the guest binary, built from
logos-co/lez-multisig PR #45 or later, ImageID 2ced3d30…d4c7.

Rules:
- The sequencer is untrusted, user-configured infrastructure (invariant 8). Muster reaches
  it only through JSON-RPC (`wallet/lez_multisig_live.nim`) and through lez_core.
- Keys stay in the TEST's keystores and wallets: member keys are keystore-derived, a
  muster wallet's keys stay in its lez_core, and the funder's stay in the CLI's home.
  muster never holds the funder's key.
- Keep the chain fresh per run. The e2e uses random create keys and labels, so a reused
  chain also works, but a fresh one is the reproducible case.
- The build traps (libclang for RocksDB, r0vm for genesis, a C++ compiler and its rpath)
  are in the script header and `docs/labbook/lez-multisig-versions.md`.
