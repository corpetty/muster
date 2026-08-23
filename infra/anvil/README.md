# infra/anvil — the P2 Safe fixture

`src/MiniSafe.sol` is a **faithful subset of Safe 1.4.1** for the P2 anvil
fixture: identical EIP-712 `DOMAIN_TYPEHASH` / `SAFE_TX_TYPEHASH` constants, the
same `safeTxHash` computation, on-chain `ecrecover` `checkSignatures`
(ascending-owner dedup + threshold), and `execTransaction`. It stands in for the
full Safe 1.4.1 singleton deployment; muster computes the identical safeTxHash
off-chain, collects owner signatures, and submits `execTransaction` here. Swapping
in the real Safe 1.4.1 singleton is a fixture change, not a muster change.

## Run the end-to-end (collect 2-of-3 off-chain, execute on-chain, no indexer)

```bash
# 1. one command: start anvil, deploy MiniSafe (2-of-3), fund it. Prints SAFE_ADDR.
./devnet.sh          # needs foundry (anvil/forge/cast)

# 2. drive it from muster. secp is nim-secp256k1 now (no system lib) — put its
#    closure on the path (clone once; see module/tests/README.md for $SECP):
cd ../../module
nim r -d:release --threads:on $SECP tests/safe_anvil_e2e.nim <SAFE_ADDR>
```

Verified 2026-08-23 on nim-secp256k1: `execTransaction succeeded on-chain
(checkSignatures passed -> local safeTxHash matched) ... OK` — the migration
produces on-chain-valid signatures, not just unit-test-valid ones.

Expected: `execTransaction succeeded on-chain (...) ... 2-of-3 collected off-chain,
executed on-chain, no indexer: OK`. A successful `execTransaction` is itself proof
that muster's local safeTxHash matched the contract's on-chain `getTxHash` — the
contract reverts otherwise.
