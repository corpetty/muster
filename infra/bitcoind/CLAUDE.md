# infra/bitcoind/

A regtest Bitcoin Core for the Phase B multisig families (exo-a50.2.5): `regtest.sh`
starts a FRESH chain each run (RPC `127.0.0.1:18443`, `muster`/`muster`, `-txindex`,
a fallback fee), `regtest.sh stop` stops it. `.data/` is the node's datadir — gitignored,
wiped on every start. Binaries from `nix shell nixpkgs#bitcoind`.

Rules: the node is untrusted, user-configured infrastructure (invariant 8) — muster's
`BitcoindAdapter` uses no wallet on it and holds no key; wallets created here belong to
the TEST (`module/tests/btc_regtest_e2e.nim`: a miner, and the outside signer `carol`).
Keep the chain fresh per run: the exit test assumes an empty account history.
