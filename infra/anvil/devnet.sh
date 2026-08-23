#!/usr/bin/env bash
# One-command anvil devnet with the MiniSafe fixture deployed + funded.
# Prints SAFE_ADDR/RPC for pointing the on-chain tests (safe_anvil_e2e, the wallet
# EVM paths) at it. Needs foundry (anvil/forge/cast) + jq.
#
# Sidecars for the other deferred end-to-end paths (documented, not started here —
# they need their own built binaries + external endpoints):
#   • delivery node (P3 two-instance test): logos-delivery-module embeds a Waku
#     node; run two hosts against store nodes.
#   • verified-proxy (trustless state root for wallet_verified_balance):
#       nimbus_verified_proxy --network=mainnet --trusted-block-root=0x<recent> \
#         --execution-api-url=<EL that supports eth_getProof> \
#         --beacon-api-url=<beacon REST> --listen-url=http://127.0.0.1:8546
#     then point the wallet's EVM RPC at http://127.0.0.1:8546 and feed its
#     verified stateRoot to wallet_verified_balance.
set -euo pipefail
cd "$(dirname "$0")"

RPC=http://127.0.0.1:8545
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNERS="[0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC]"

if ! cast block-number --rpc-url $RPC >/dev/null 2>&1; then
  echo "→ starting anvil (chainId 31337)"
  anvil --silent &
  for _ in $(seq 1 50); do cast block-number --rpc-url $RPC >/dev/null 2>&1 && break; sleep 0.2; done
else
  echo "→ anvil already up on $RPC"
fi

echo "→ deploying MiniSafe (2-of-3, anvil owners 0/1/2)"
SAFE=$(forge create --rpc-url $RPC --private-key $K0 --broadcast \
  src/MiniSafe.sol:MiniSafe --constructor-args "$OWNERS" 2 2>&1 \
  | grep -oiE "Deployed to: 0x[0-9a-fA-F]{40}" | grep -oiE "0x[0-9a-fA-F]{40}")

echo "→ funding $SAFE with 5 ETH"
cast send --rpc-url $RPC --private-key $K0 --value 5ether "$SAFE" >/dev/null

echo
echo "SAFE_ADDR=$SAFE"
echo "RPC=$RPC"
