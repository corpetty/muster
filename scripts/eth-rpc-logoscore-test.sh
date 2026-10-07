#!/usr/bin/env bash
# Headless, under logoscore 0.3.1 (exo-d4d.3, R2): muster reads a chain through the
# platform's eth_rpc_module, not through a URL of its own.
#
# One logoscore daemon over the modules a Basecamp profile installed
# (scripts/basecamp-profile.sh <name> --no-launch): the default catalog's packages plus
# muster_module from this tree. Then, with no MUSTER_RPC and nothing seeded:
#   1. muster calls eth_rpc_module.init_defaults, so the person's registry holds chains;
#   2. evm-chains = url: muster's own RPC URL (the default, a local anvil nobody started)
#      cannot read a token on Ethereum: the read fails, and nothing is guessed;
#   3. evm-chains = platform: the same read goes through eth_rpc_module and answers
#      USDC's symbol and decimals from Ethereum mainnet;
#   4. settings() says the platform is in use.
# Needs the network (eth_rpc_module's default endpoints are publicnode.com).
#
#   scripts/eth-rpc-logoscore-test.sh [profile]     # default profile: alice
set -uo pipefail
cd "$(dirname "$0")/.."
PROFILE=.run/basecamp/${1:-alice}
[ -d "$PROFILE/modules/muster_module" ] || { echo "install a profile first: scripts/basecamp-profile.sh ${1:-alice} --no-launch"; exit 1; }
CACHE=(--accept-flake-config --extra-substituters https://cache.nix.logos.co/public
       --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=)
# the PORTABLE bundle: a plain `cli` build is a dev host, which refuses the catalog's
# linux-amd64 packages ("installed for variant 'linux-amd64' which is not supported")
L="$(nix build "github:logos-co/logos-logoscore-cli/${LOGOSCORE_REV:-0.3.1}#cli-bundle-dir" --no-link --print-out-paths "${CACHE[@]}" 2>/dev/null | tail -1)/bin/logoscore"
[ -x "$L" ] || { echo "logoscore did not build"; exit 1; }

D=$(mktemp -d); mkdir -p "$D/cfg" "$D/data"
cp -rL --no-preserve=mode "$PROFILE/modules" "$D/mods"
MUSTER_DATA_DIR="$D/data" MUSTER_DELIVERY_CONFIG=local \
  setsid "$L" --config-dir "$D/cfg" daemon -m "$D/mods" --persistence-path "$D/cfg/data" >"$D/daemon.log" 2>&1 &
DPID=$!
lc() { timeout 90 "$L" --config-dir "$D/cfg" "$@" 2>&1 | tail -1; }
cleanup() { lc stop >/dev/null; kill -9 -"$DPID" 2>/dev/null; kill -9 "$DPID" 2>/dev/null; [ -n "${KEEP_LOGS:-}" ] && echo "logs: $D" || rm -rf "$D"; }
trap cleanup EXIT
for _ in $(seq 1 30); do lc status >/dev/null && break; sleep 1; done
for m in eth_rpc_module muster_module; do lc load-module "$m" >/dev/null; done

res() { python3 -c 'import sys,json
try:
  r=json.load(sys.stdin)["result"]; print(r if isinstance(r,str) else json.dumps(r))
except Exception as e: print("")'; }
ok=1
USDC=0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48

echo "── 1. muster seeds the registry (init_defaults, once)"
lc call muster_module set_setting evm-chains auto | res >/dev/null
lc call muster_module settings | res >/dev/null          # evmPlatform() → init_defaults + list_chain_configs
REG=$(lc call eth_rpc_module list_chain_configs | res)
echo "$REG" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); ids=[c["chainId"] for c in d["chains"]]; print("   chains:", ids); sys.exit(0 if 1 in ids else 1)' || { echo "FAIL no registry"; ok=0; }

echo "── 2. evm-chains = url: muster's own URL cannot read Ethereum"
lc call muster_module set_setting evm-chains url | res >/dev/null
T=$(lc call muster_module coordinate_token_info eip155:1 $USDC | res); echo "   $T"
echo "$T" | grep -q '"symbol":"USDC"' && { echo "FAIL read without the platform"; ok=0; }

echo "── 3. evm-chains = platform: the same read through eth_rpc_module"
lc call muster_module set_setting evm-chains platform | res >/dev/null
T=$(lc call muster_module coordinate_token_info eip155:1 $USDC | res); echo "   $T"
echo "$T" | grep -q '"symbol":"USDC"' && echo "$T" | grep -q '"decimals":6' || { echo "FAIL no read through eth_rpc_module"; ok=0; }

echo "── 4. settings() names the platform"
S=$(lc call muster_module settings | res)
echo "$S" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print("   evmChains:", d.get("evmChains"), "evmPlatform:", d.get("evmPlatform")); sys.exit(0 if d.get("evmPlatform") else 1)' || { echo "FAIL"; ok=0; }

[ $ok = 1 ] && echo "PASS eth-rpc-logoscore-test" || { echo "FAIL eth-rpc-logoscore-test (KEEP_LOGS=1 to keep $D)"; exit 1; }
