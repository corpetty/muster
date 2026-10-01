#!/usr/bin/env bash
# A split paid in Bitcoin, end to end through the real UI binary (exo-d17) — no GUI, no
# clicks. Two offscreen runners on the Logos fleet and a fresh Bitcoin Core regtest node:
#   A (founder, seeded with anvil key 0) admits B, and once B is in proposes splitting
#     0.003 BTC it fronted (MUSTER_AUTOSPLIT + MUSTER_AUTOSPLIT_CHAIN=<regtest> — the Split
#     composer's slot), paid at A's own wpkh address;
#   B (anvil key 1) holds 0.01 BTC at wpkh(<its own key>), agrees to its 0.0015 BTC share
#     and pays it from its own coins through its own node (MUSTER_AUTOPAYSPLIT);
#   this script mines a block every few seconds; A's client confirms B's payment from its
#     own node once it is in a block.
# Passes when both instances log the split final and A's address received exactly B's
# share. Both runners use MUSTER_BTC_RPC=<this regtest node>, never a node you run.
#
# Needs bitcoind + bitcoin-cli on PATH:
#   make build && nix shell nixpkgs#bitcoind -c scripts/split-btc-self-test.sh   # KEEP_LOGS=1
#
# The regtest node is infra/bitcoind/regtest.sh's (a FRESH chain each run). Cleanup kills
# only this script's own processes (each runner's session), never another muster you run.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
command -v bitcoind >/dev/null && command -v bitcoin-cli >/dev/null ||
  { echo "needs bitcoind + bitcoin-cli: nix shell nixpkgs#bitcoind -c $0"; exit 1; }

KEY0=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil account 0
KEY1=59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d   # anvil account 1
CHAIN=bip122:0f9188f13cb7b2c71f2a335e3a4fc328                          # regtest
TOTAL=300000   # sat: A's own share 150000, B owes 150000
SHARE=150000
BTC_RPC=http://muster:muster@127.0.0.1:18443
CLI=(bitcoin-cli -regtest -datadir="$PWD/infra/bitcoind/.data" -rpcport=18443 -rpcuser=muster -rpcpassword=muster)

infra/bitcoind/regtest.sh >/dev/null || { echo "could not start the regtest node"; exit 1; }

# wpkh(<key>) for a raw secp256k1 key: WIF (regtest, compressed), then the node derives it
wif() { python3 - "$1" <<'PY'
import hashlib, sys
k = bytes.fromhex(sys.argv[1]); p = b"\xef" + k + b"\x01"
c = hashlib.sha256(hashlib.sha256(p).digest()).digest()[:4]
n = int.from_bytes(p + c, "big"); a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; s = ""
while n: n, r = divmod(n, 58); s = a[r] + s
print(s)
PY
}
wpkh() {
  local d; d=$("${CLI[@]}" getdescriptorinfo "wpkh($(wif "$1"))" | python3 -c 'import json,sys;print(json.load(sys.stdin)["descriptor"])')
  "${CLI[@]}" deriveaddresses "$d" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0])'
}
ADDR_A=$(wpkh "$KEY0")
ADDR_B=$(wpkh "$KEY1")
received() { "${CLI[@]}" scantxoutset start "[\"addr($1)\"]" | python3 -c 'import json,sys;print(round(json.load(sys.stdin)["total_amount"]*1e8))'; }

"${CLI[@]}" -named createwallet wallet_name=miner load_on_startup=false >/dev/null
MINER=$("${CLI[@]}" -rpcwallet=miner getnewaddress "" bech32)
"${CLI[@]}" generatetoaddress 101 "$MINER" >/dev/null
"${CLI[@]}" -rpcwallet=miner sendtoaddress "$ADDR_B" 0.01 >/dev/null
"${CLI[@]}" generatetoaddress 1 "$MINER" >/dev/null
BEFORE=$(received "$ADDR_A")
echo "regtest up · A is paid at $ADDR_A · B holds 0.01 BTC at $ADDR_B"

CFG=$(ui_fleet_config)
TOPIC="/muster/1/split-btc-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC · logs: $D"

launch() {  # name, extra env… — each runner in its own session, so cleanup can find it
  local name="$1"; shift
  env "$@" MUSTER_BTC_RPC="$BTC_RPC" MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" \
      MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID="splitbtc$name" QT_QPA_PLATFORM=offscreen \
      setsid "$RUNNER" --user-dir "$D/$name" >"$D/$name.log" 2>&1 &
  echo $! >"$D/$name.pid"
  disown $!
}
launch A MUSTER_DEV_SECP_KEY="0x$KEY0" MUSTER_AUTOADMIT=1 MUSTER_AUTOSPLIT="$TOTAL" MUSTER_AUTOSPLIT_CHAIN="$CHAIN"
sleep 3
launch B MUSTER_DEV_SECP_KEY="0x$KEY1" MUSTER_AUTOPAYSPLIT=1

cleanup() {
  for n in A B; do
    local pid sid
    pid=$(cat "$D/$n.pid" 2>/dev/null) || continue
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$sid" ] && pkill -9 -s "$sid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
  done
  infra/bitcoind/regtest.sh stop >/dev/null 2>&1
}
trap cleanup EXIT

final() { grep -aqE 'MUSTER-LP split [0-9a-fx]+ state=final' "$D/$1.log" 2>/dev/null; }
echo "watching for the split to reach final on both instances (up to 240s), mining a block every 3s..."
ok=0
for i in $(seq 1 80); do
  sleep 3
  "${CLI[@]}" generatetoaddress 1 "$MINER" >/dev/null
  final A && final B && { ok=1; break; }
done

saw() { grep -aqE "$1" "$D/$2.log" 2>/dev/null && echo yes || echo no; }
echo "A members=2: $(saw 'members=2' A) · A proposed: $(saw 'MUSTER-LP split propose 0x' A)" \
     "· B paid: $(saw 'MUSTER-LP split pay .*pending' B) · B reported: $(saw 'MUSTER-LP split reported' B)" \
     "· A confirmed: $(saw 'MUSTER-LP split confirmed' A)"
grep -ahE 'MUSTER-LP split ' "$D/A.log" | tail -5 | sed 's/^/  A │ /'
grep -ahE 'MUSTER-LP split ' "$D/B.log" | tail -5 | sed 's/^/  B │ /'

GAIN=$(( $(received "$ADDR_A") - BEFORE ))
if [ "$ok" = 1 ] && [ "$GAIN" = "$SHARE" ]; then
  echo "SUCCESS after ~$((i * 3))s: final on both instances; A received exactly B's share ($GAIN sat)."
  cleanup; trap - EXIT
  [ -n "${KEEP_LOGS:-}" ] && echo "logs kept in $D" || rm -rf "$D"
else
  echo "FAIL: final on both=$ok, A gained $GAIN sat (want $SHARE) — logs kept in $D"
  exit 1
fi
