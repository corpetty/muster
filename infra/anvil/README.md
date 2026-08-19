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
# 1. anvil (chainId 31337, funded/unlocked accounts)
anvil --silent &

# 2. deploy MiniSafe with anvil accounts 0/1/2 as owners, threshold 2
cd infra/anvil
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge create --rpc-url http://127.0.0.1:8545 --private-key $K0 --broadcast \
  src/MiniSafe.sol:MiniSafe \
  --constructor-args "[0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC]" 2
# fund it
cast send --rpc-url http://127.0.0.1:8545 --private-key $K0 --value 5ether <SAFE_ADDR>

# 3. drive it from muster (needs libsecp256k1 linked)
nix build nixpkgs#secp256k1 --out-link /tmp/secp
cd ../../module
nim r -d:release --passC:-I/tmp/secp/include --passL:/tmp/secp/lib/libsecp256k1.so \
  tests/safe_anvil_e2e.nim <SAFE_ADDR>
```

Expected: `execTransaction succeeded on-chain (...) ... 2-of-3 collected off-chain,
executed on-chain, no indexer: OK`. A successful `execTransaction` is itself proof
that muster's local safeTxHash matched the contract's on-chain `getTxHash` — the
contract reverts otherwise.
