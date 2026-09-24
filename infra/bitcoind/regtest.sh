#!/usr/bin/env bash
# One-command Bitcoin Core regtest node for the Phase B multisig families (exo-a50.2.5):
# a FRESH chain each run (the datadir is wiped — the exit test assumes an empty chain),
# RPC on 127.0.0.1:18443 with user/password muster/muster, -txindex so a confirmed
# transaction's finality can be read, and a fallback fee so the test's miner wallet can
# fund accounts on a chain with no fee history. Muster's own adapter never uses a
# wallet: the node's wallets here are the TEST's (a miner, and an outside signer).
#
# Needs bitcoind + bitcoin-cli on PATH (`nix shell nixpkgs#bitcoind` works). Runs in
# the background; `infra/bitcoind/regtest.sh stop` stops it.
set -euo pipefail
cd "$(dirname "$0")"

DATA=${BTC_DATADIR:-$PWD/.data}     # gitignored
PORT=${BTC_RPCPORT:-18443}
CLI=(bitcoin-cli -regtest -datadir="$DATA" -rpcport="$PORT" -rpcuser=muster -rpcpassword=muster)

if [ "${1:-}" = "stop" ]; then
  "${CLI[@]}" stop 2>/dev/null || echo "→ no regtest node running"
  exit 0
fi

if "${CLI[@]}" getblockcount >/dev/null 2>&1; then
  echo "→ stopping the running regtest node (a fresh chain each run)"
  "${CLI[@]}" stop >/dev/null
  for _ in $(seq 1 50); do "${CLI[@]}" getblockcount >/dev/null 2>&1 || break; sleep 0.2; done
fi

rm -rf "$DATA"
mkdir -p "$DATA"
echo "→ starting bitcoind -regtest (rpc 127.0.0.1:$PORT, user muster)"
bitcoind -regtest -daemon -datadir="$DATA" -rpcport="$PORT" -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
  -rpcuser=muster -rpcpassword=muster -txindex=1 -fallbackfee=0.0002 -listen=0 >/dev/null
for _ in $(seq 1 100); do "${CLI[@]}" getblockcount >/dev/null 2>&1 && break; sleep 0.2; done
"${CLI[@]}" getblockcount >/dev/null
echo "RPC=http://127.0.0.1:$PORT  USER=muster  PASSWORD=muster  ($(bitcoind --version | head -1))"
