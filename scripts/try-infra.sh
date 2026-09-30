#!/usr/bin/env bash
# The local infrastructure for trying muster with two instances, in one command
# (docs/runbooks/client-tour.md). Everything a step needs (addresses, keys, the node
# command) is written to .run/try/env.
#
#   scripts/try-infra.sh up       anvil + the real Safe v1.4.1 + the MTD test token;
#                                 a Bitcoin regtest with each peer's payer address funded,
#                                 a funded 2-of-3 P2WSH and taproot multisig (Alice, Bob,
#                                 and Carol as the signer outside muster), and a miner
#                                 that mines a block every 10 s; checks the LEZ testnet
#   scripts/try-infra.sh status
#   scripts/try-infra.sh env      print .run/try/env
#   scripts/try-infra.sh btc …    bitcoin-cli against this node (e.g. btc -rpcwallet=carol …)
#   scripts/try-infra.sh eth …    cast against this anvil (e.g. eth balance 0x…)
#   scripts/try-infra.sh down     stop only what `up` started
#
#   up --no-evm | --no-btc        skip a chain
#
# Ports of its own, so it never meets another chain on this machine: anvil on 8555
# (TRY_EVM_PORT) and bitcoind on 18453 (TRY_BTC_PORT) with its datadir under .run/try.
# A devnet you already run keeps 8545, and the Bitcoin self-tests' regtest.sh, which
# wipes whatever node answers on 18443, never touches this session's chain.
# `up` always starts fresh chains: it stops its own earlier run first.
#
# The peers: scripts/try-peer.sh alice | bob | carol, which reads .run/try/env.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
STATE=$ROOT/.run/try
ENVF=$STATE/env
EVM_PORT=${TRY_EVM_PORT:-8555}
RPC=http://127.0.0.1:$EVM_PORT
BTC_PORT=${TRY_BTC_PORT:-18453}
BTC_DATA=$STATE/bitcoind
NUMS=50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0   # module/src/bitcoin/taproot.nim
LEZ_URL=${TRY_LEZ_RPC:-https://testnet.lez.logos.co}

# anvil's deterministic accounts: 0 = Alice, 1 = Bob, 2 = Carol (the Safe's owners, and
# the keys scripts/try-peer.sh seeds); 9 deploys the test token.
KEY_ALICE=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
KEY_BOB=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
KEY_CAROL=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
KEY_9=0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6

# The tools, from nix when they are not on PATH.
if [ -z "${TRY_IN_NIX:-}" ]; then
  for t in anvil cast forge jq git bitcoind bitcoin-cli curl python3; do
    command -v "$t" >/dev/null 2>&1 || {
      exec env TRY_IN_NIX=1 nix shell nixpkgs#foundry nixpkgs#jq nixpkgs#git nixpkgs#bitcoind \
        nixpkgs#curl nixpkgs#python3 -c "$0" "$@"
    }
  done
fi

say() { echo "→ $*"; }
bcli() { bitcoin-cli -regtest -datadir="$BTC_DATA" -rpcport="$BTC_PORT" -rpcuser=muster -rpcpassword=muster "$@"; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
# Start a background process in its own session and record its pid from inside it
# (setsid forks when its caller leads a process group, and then $! would name the
# wrong process).
spawn() {
  local pidfile=$1 log=$2; shift 2
  setsid bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pidfile" "$@" >"$log" 2>&1 < /dev/null &
  for _ in $(seq 1 50); do [ -s "$pidfile" ] && break; sleep 0.1; done
}
eth_up() {
  curl -s -m 2 -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC" 2>/dev/null | grep -q '"result"'
}

# A compressed secp256k1 public key, from `cast`'s uncompressed x||y.
compressed() {
  local u y
  u=$(cast wallet public-key --private-key "$1"); u=${u#0x}; y=${u:64:64}
  if (( 16#${y:62:2} % 2 )); then echo "03${u:0:64}"; else echo "02${u:0:64}"; fi
}
# A regtest WIF for Bitcoin Core (base58check of 0xef ‖ key ‖ 0x01, compressed).
wif() {
  python3 - "$1" <<'PY'
import hashlib, sys
k = bytes.fromhex(sys.argv[1].removeprefix("0x"))
p = b"\xef" + k + b"\x01"
p += hashlib.sha256(hashlib.sha256(p).digest()).digest()[:4]
a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n, s = int.from_bytes(p, "big"), ""
while n: n, r = divmod(n, 58); s = a[r] + s
print("1" * (len(p) - len(p.lstrip(b"\0"))) + s)
PY
}
with_checksum() { echo "$1#$(bcli getdescriptorinfo "$1" | jq -r .checksum)"; }
address_of() { bcli deriveaddresses "$(with_checksum "$1")" | jq -r '.[0]'; }

down() {
  if alive "$STATE/miner.pid"; then say "stopping the miner"; kill "$(cat "$STATE/miner.pid")" 2>/dev/null || true; fi
  if [ -d "$BTC_DATA" ] && bcli getblockcount >/dev/null 2>&1; then
    say "stopping bitcoind (regtest :$BTC_PORT)"
    bcli stop >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do bcli getblockcount >/dev/null 2>&1 || break; sleep 0.2; done
  fi
  if alive "$STATE/anvil.pid"; then say "stopping anvil (:$EVM_PORT)"; kill "$(cat "$STATE/anvil.pid")" 2>/dev/null || true; fi
  rm -f "$STATE"/*.pid
}

evm_up() {
  if eth_up; then
    echo "something already answers on $RPC and was not started here. Pick another port (TRY_EVM_PORT=…), or run 'up --no-evm'." >&2
    exit 1
  fi
  say "starting anvil on $RPC (chain 31337)"
  spawn "$STATE/anvil.pid" "$STATE/anvil.log" anvil --host 127.0.0.1 --port "$EVM_PORT" --silent
  for _ in $(seq 1 50); do eth_up && break; sleep 0.2; done
  eth_up || { echo "anvil did not start (see $STATE/anvil.log)" >&2; exit 1; }
  say "deploying the real Safe v1.4.1 (infra/anvil/devnet.sh)"
  ANVIL_PORT="$EVM_PORT" infra/anvil/devnet.sh >"$STATE/devnet.log" 2>&1 || { tail -20 "$STATE/devnet.log"; exit 1; }
  SAFE=$(grep -oE '^SAFE_ADDR=0x[0-9a-fA-F]{40}' "$STATE/devnet.log" | cut -d= -f2)
  say "deploying the MTD test token (6 decimals) and minting 1000 MTD to Alice, Bob and Carol"
  TOKEN=$(cast send --rpc-url "$RPC" --private-key "$KEY_9" --json \
    --create "0x$(tr -d '[:space:]' < module/tests/fixtures/MusterTestToken.bin)" | jq -r .contractAddress)
  for k in "$KEY_ALICE" "$KEY_BOB" "$KEY_CAROL"; do
    cast send --rpc-url "$RPC" --private-key "$KEY_9" "$TOKEN" "mint(address,uint256)" \
      "$(cast wallet address --private-key "$k")" 1000000000 >/dev/null
  done
  {
    echo "TRY_RPC=$RPC"
    echo "TRY_SAFE=$SAFE"
    echo "TRY_TOKEN=$TOKEN"
    echo "TRY_ALICE_EVM=$(cast wallet address --private-key "$KEY_ALICE")"
    echo "TRY_BOB_EVM=$(cast wallet address --private-key "$KEY_BOB")"
    echo "TRY_CAROL_EVM=$(cast wallet address --private-key "$KEY_CAROL")"
  } >> "$ENVF"
}

btc_up() {
  say "starting a fresh Bitcoin regtest on :$BTC_PORT (datadir $BTC_DATA)"
  BTC_DATADIR="$BTC_DATA" BTC_RPCPORT="$BTC_PORT" infra/bitcoind/regtest.sh >"$STATE/bitcoind.log" 2>&1 \
    || { cat "$STATE/bitcoind.log"; exit 1; }
  bcli -named createwallet wallet_name=miner load_on_startup=false >/dev/null
  local miner; miner=$(bcli -rpcwallet=miner getnewaddress "" bech32)
  bcli generatetoaddress 101 "$miner" >/dev/null
  local A B C CW
  A=$(compressed "$KEY_ALICE"); B=$(compressed "$KEY_BOB"); C=$(compressed "$KEY_CAROL"); CW=$(wif "$KEY_CAROL")
  # Each peer pays a Bitcoin split from wpkh(its own muster key).
  local alice bob
  alice=$(address_of "wpkh($A)"); bob=$(address_of "wpkh($B)")
  say "funding Alice's and Bob's payer addresses (0.05 BTC each)"
  bcli -rpcwallet=miner sendtoaddress "$alice" 0.05 >/dev/null
  bcli -rpcwallet=miner sendtoaddress "$bob" 0.05 >/dev/null
  # A 2-of-3 over Alice, Bob and Carol, where Carol signs outside muster: her Bitcoin
  # Core wallet holds her key (the same descriptors module/tests/btc_regtest_e2e.nim uses).
  bcli -named createwallet wallet_name=carol blank=true load_on_startup=false >/dev/null
  local wsh tr
  wsh=$(with_checksum "wsh(sortedmulti(2,$A,$B,$CW))")
  tr=$(with_checksum "tr($NUMS,sortedmulti_a(2,${A:2},${B:2},$CW))")
  bcli -rpcwallet=carol importdescriptors "[{\"desc\":\"$wsh\",\"timestamp\":\"now\"},{\"desc\":\"$tr\",\"timestamp\":\"now\"}]" >/dev/null
  local wshAddr trAddr
  wshAddr=$(bcli deriveaddresses "$wsh" | jq -r '.[0]'); trAddr=$(bcli deriveaddresses "$tr" | jq -r '.[0]')
  say "funding the 2-of-3 P2WSH and taproot multisigs (1 BTC each)"
  bcli -rpcwallet=miner sendtoaddress "$wshAddr" 1.0 >/dev/null
  bcli -rpcwallet=miner sendtoaddress "$trAddr" 1.0 >/dev/null
  bcli generatetoaddress 1 "$miner" >/dev/null
  say "starting the miner: a block every 10 s (payments confirm without anyone mining)"
  spawn "$STATE/miner.pid" "$STATE/miner.log" bash -c \
    "while bitcoin-cli -regtest -datadir='$BTC_DATA' -rpcport=$BTC_PORT -rpcuser=muster -rpcpassword=muster generatetoaddress 1 $miner >/dev/null 2>&1; do sleep 10; done"
  {
    echo "TRY_BTC_RPC=http://muster:muster@127.0.0.1:$BTC_PORT"
    echo "TRY_BTC_CLI='bitcoin-cli -regtest -datadir=$BTC_DATA -rpcport=$BTC_PORT -rpcuser=muster -rpcpassword=muster'"
    echo "TRY_BTC_MINER=$miner"
    echo "TRY_ALICE_BTC=$alice"
    echo "TRY_BOB_BTC=$bob"
    echo "TRY_KEY_ALICE=$A"
    echo "TRY_KEY_BOB=$B"
    echo "TRY_KEY_CAROL=$C"
    echo "TRY_P2WSH=$wshAddr"
    echo "TRY_TAPROOT=$trAddr"
  } >> "$ENVF"
}

lez_check() {
  if curl -s -m 10 -X POST -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"getLastBlockId","params":{}}' "$LEZ_URL" | grep -q '"result"'; then
    say "the LEZ testnet answers ($LEZ_URL)"; echo "TRY_LEZ=up" >> "$ENVF"
  else
    say "the LEZ testnet does not answer ($LEZ_URL): the LEZ parts of the tour will wait"; echo "TRY_LEZ=down" >> "$ENVF"
  fi
}

status() {
  echo "anvil     $(eth_up && echo "up on $RPC" || echo down)$(alive "$STATE/anvil.pid" && echo " (started here)")"
  if [ -d "$BTC_DATA" ] && bcli getblockcount >/dev/null 2>&1; then
    echo "bitcoind  up on :$BTC_PORT, height $(bcli getblockcount)"
  else echo "bitcoind  down"; fi
  echo "miner     $(alive "$STATE/miner.pid" && echo running || echo stopped)"
  [ -f "$ENVF" ] && echo "env       $ENVF" || echo "env       none (run: scripts/try-infra.sh up)"
}

case "${1:-}" in
  up)
    shift; evm=1; btc=1
    for a in "$@"; do case "$a" in --no-evm) evm=0 ;; --no-btc) btc=0 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac; done
    mkdir -p "$STATE"
    down
    : > "$ENVF"
    echo "# written by scripts/try-infra.sh up, $(date -u +%FT%TZ)" >> "$ENVF"
    [ $evm = 1 ] && evm_up
    [ $btc = 1 ] && btc_up
    lez_check
    echo
    status
    echo
    echo "Next: scripts/try-peer.sh alice   (and bob, in a second terminal)"
    ;;
  down) down ;;
  status) status ;;
  btc) shift; bcli "$@" ;;
  eth) shift; [ $# -gt 0 ] || { echo "usage: $0 eth <cast subcommand> …" >&2; exit 2; }; cast "$@" --rpc-url "$RPC" ;;
  env) cat "$ENVF" ;;
  *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
