#!/usr/bin/env bash
# One-command anvil devnet with a REAL Safe v1.4.1 deployed + funded (exo-a50.1.4):
# the Safe singleton, SafeProxyFactory and CompatibilityFallbackHandler from
# safe-global/safe-smart-account at the pinned tag, then a 2-of-3 proxy owned by anvil
# accounts 0/1/2 — the same contracts a mainnet Safe runs, so muster's safeTxHash,
# its ten-argument execTransaction, getOwners/getThreshold and the module/guard reads
# are all exercised against the real thing. (It replaced MiniSafe, a four-argument
# subset the real Safe does not have.) Deterministic on a fresh anvil.
# Prints SAFE_ADDR/RPC. Needs foundry (anvil/forge/cast) + jq + git
# (`nix shell nixpkgs#foundry` works).
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
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
OWNERS="[0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC]"
ZERO=0x0000000000000000000000000000000000000000
SAFE_REF=v1.4.1
LIB=lib/safe-smart-account   # fetched at the pinned tag; gitignored
OUT=out-safe

# Bind address for anvil's RPC. Default 127.0.0.1 (local-only, the safe default).
# For a TWO-MACHINE demo where a second peer must reach this Safe chain over the LAN,
# start with ANVIL_HOST=0.0.0.0 — anvil then listens on all interfaces and the second
# peer points its RPC (Settings, or MUSTER_RPC) at http://<this-machine-LAN-IP>:8545.
# All local calls below (deploy/fund) still use 127.0.0.1.
ANVIL_HOST=${ANVIL_HOST:-127.0.0.1}

if ! cast block-number --rpc-url $RPC >/dev/null 2>&1; then
  echo "→ starting anvil (chainId 31337, host $ANVIL_HOST)"
  anvil --silent --host "$ANVIL_HOST" &
  for _ in $(seq 1 50); do cast block-number --rpc-url $RPC >/dev/null 2>&1 && break; sleep 0.2; done
else
  echo "→ anvil already up on $RPC"
fi

if [ ! -d "$LIB/contracts" ]; then
  echo "→ fetching safe-smart-account $SAFE_REF"
  git clone -q --depth 1 --branch "$SAFE_REF" https://github.com/safe-global/safe-smart-account "$LIB"
  # the repo's test/ and examples/ contracts need other compilers; the fixture uses none of them
  rm -rf "$LIB/contracts/test" "$LIB/contracts/examples"
fi
if [ ! -f "$OUT/Safe.sol/Safe.json" ]; then
  echo "→ building Safe $SAFE_REF (solc 0.7.6, the release compiler)"
  (cd "$LIB" && forge build contracts/Safe.sol contracts/proxies/SafeProxyFactory.sol \
     contracts/handler/CompatibilityFallbackHandler.sol --use 0.7.6 --out "../../$OUT" >/dev/null)
fi

deploy() {  # deploy <artifact-path> → prints the created address
  local code; code=$(jq -r '.bytecode.object' "$1")
  cast send --rpc-url $RPC --private-key $K0 --create "$code" --json | jq -r '.contractAddress'
}

echo "→ deploying Safe $SAFE_REF singleton, proxy factory, fallback handler"
SINGLETON=$(deploy "$OUT/Safe.sol/Safe.json")
FACTORY=$(deploy "$OUT/SafeProxyFactory.sol/SafeProxyFactory.json")
FALLBACK=$(deploy "$OUT/CompatibilityFallbackHandler.sol/CompatibilityFallbackHandler.json")

echo "→ creating the 2-of-3 Safe (owners = anvil accounts 0/1/2)"
INIT=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
  "$OWNERS" 2 $ZERO 0x "$FALLBACK" $ZERO 0 $ZERO)
SAFE=$(cast call --rpc-url $RPC --from $A0 "$FACTORY" \
  "createProxyWithNonce(address,bytes,uint256)(address)" "$SINGLETON" "$INIT" 0)
cast send --rpc-url $RPC --private-key $K0 "$FACTORY" \
  "createProxyWithNonce(address,bytes,uint256)" "$SINGLETON" "$INIT" 0 >/dev/null

echo "→ funding $SAFE with 5 ETH"
cast send --rpc-url $RPC --private-key $K0 --value 5ether "$SAFE" >/dev/null

echo "→ check: $(cast call --rpc-url $RPC "$SAFE" 'VERSION()(string)') · threshold $(cast call --rpc-url $RPC "$SAFE" 'getThreshold()(uint256)') · owners $(cast call --rpc-url $RPC "$SAFE" 'getOwners()(address[])')"
echo
echo "SAFE_ADDR=$SAFE"
echo "SINGLETON=$SINGLETON FACTORY=$FACTORY FALLBACK=$FALLBACK"
echo "RPC=$RPC"
if [ "$ANVIL_HOST" = "0.0.0.0" ]; then
  LANIP=$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
  [ -n "$LANIP" ] && echo "LAN_RPC=http://$LANIP:8545   # point the second peer's RPC here (Settings or MUSTER_RPC)"
fi
