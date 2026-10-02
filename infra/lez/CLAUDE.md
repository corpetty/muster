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

`funder.sh` is the zone's funder for ANY zone (exo-eb6.4.5): one wallet of LEZ's CLI per zone
— the local zone's is the genesis funder above, the testnet's lives in
`~/.cache/muster/lez-funder-testnet` — whose single public account is what someone holding
native LEZ funds once; `funder.sh --zone testnet account` prints it. `account | balance |
fund <id> <amount> | deploy <prog.bin>`; `localnet.sh fund` and `deploy` delegate to it. The
v0.3 e2e tests and `scripts/split-lez-testnet.sh` fund their accounts through it on the zone
their URL names (`tests/probes/lez_funding.nim`, `MUSTER_LEZ_E2E_FUND` per account). The
funder's key is in its wallet home on THIS machine: another machine needs that directory
copied, or its own funder funded.

`localnet.sh deploy <prog.bin>` deploys a v0.3 program (risc0's R0BF `.bin`) through LEZ's
`program_loader`, the funder paying, and prints the program's account id: its header
account, from which every PDA it owns is derived. The v0.3 multisig program (exo-eb6.4.4,
`docs/design/lez-multisig-v03.md`) is deployed this way, and its own e2e (`e2e_v03` in the
port's workspace) runs against this zone with `localnet.sh fund` as its funding command,
and muster's room drives it there (`module/tests/lez_multisig_live_v030_e2e.nim`).

On v0.3 a transaction whose program refuses it is still included, pays its fee and burns
its signers' nonces; the RPC reports no outcome. Judge a step by the state it changes,
never by inclusion (`docs/labbook/lez-v03-migration.md` trap 8).

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
