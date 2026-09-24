# infra/bitcoind — a regtest Bitcoin Core for the Phase B families

`regtest.sh` starts a **fresh** regtest chain every run (the datadir `.data/` is wiped,
gitignored): RPC on `127.0.0.1:18443`, user/password `muster`/`muster`, `-txindex` so a
confirmed transaction's finality can be read, and a fallback fee so a test wallet can
fund accounts on a chain with no fee history. `regtest.sh stop` stops it.

```bash
nix shell nixpkgs#bitcoind -c infra/bitcoind/regtest.sh
```

Muster's `BitcoindAdapter` (`module/src/wallet/btc_adapter.nim`) uses no wallet: it
reads an account's coins from the node's UTXO set (`scantxoutset`), broadcasts the
transaction the Bitcoin settlement finalized (`sendrawtransaction`), and reads its
confirmations. The node is untrusted, user-configured infrastructure (invariant 8).
The wallets the exit test creates here are the TEST's — a miner that funds and mines,
and `carol`, an outside signer holding the third key who signs muster's PSBT
(`module/tests/btc_regtest_e2e.nim`).
