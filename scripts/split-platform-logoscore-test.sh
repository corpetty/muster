#!/usr/bin/env bash
# A split paid through the platform, headless (exo-d4d.5, R4; docs/design/real-use-basecamp.md).
#
# Two muster instances, each in its own logoscore 0.3.1 daemon (the portable bundle) over the
# modules a Basecamp profile installs (scripts/basecamp-profile.sh <profile> --no-launch),
# peered on a local delivery pair, against a local anvil:
#   * each person's chain registry (eth_rpc_module) names the anvil as chain 31337, a testnet,
#     as a person would in eth_rpc_ui;
#   * each person's key is in their own keystore_module (imported by evm_keystore_cli, the
#     custodian), selected in muster, and linked to their room identity in the signer;
#   * Alice opens a room, admits Bob, and proposes a split on eip155:31337: Bob owes half;
#   * Bob agrees (his room key), then pays: muster asks tx_sender_module, which prepares the
#     one call muster derived and checked, and asks keystore_module for ONE approval;
#     evm_signer_cli plays the person; send_status broadcasts;
#   * Bob's report names the hash; Alice's client reads it through ITS eth_rpc_module,
#     confirms, and the split goes final on both; the anvil shows Alice paid exactly the share.
# Nothing muster-specific is seeded: no MUSTER_RPC, no MUSTER_DEV_SECP_KEY.
#
#   scripts/split-platform-logoscore-test.sh [profile]     # default: alice
#   KEEP_LOGS=1 … keeps the daemons' logs
set -uo pipefail
cd "$(dirname "$0")/.."
export MUSTER_FLEET=local
. scripts/lib/ui-build.sh >/dev/null 2>&1 || true
PROFILE=.run/basecamp/${1:-alice}
[ -d "$PROFILE/modules/muster_module" ] || { echo "install a profile first: scripts/basecamp-profile.sh ${1:-alice} --no-launch"; exit 1; }
CLI=.run/basecamp/catalog-cli
for n in evm_keystore_cli evm_signer_cli; do
  [ -f "$CLI/$n.lgx" ] || { echo "fetch $n first (infra/basecamp/catalog-0.3.1-cli.tsv → $CLI/)"; exit 1; }
done
CACHE=(--accept-flake-config --extra-substituters https://cache.nix.logos.co/public
       --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=)
L="$(nix build "github:logos-co/logos-logoscore-cli/${LOGOSCORE_REV:-0.3.1}#cli-bundle-dir" --no-link --print-out-paths "${CACHE[@]}" 2>/dev/null | tail -1)/bin/logoscore"
LGPM="$(nix build github:logos-co/logos-package-manager/3133786ea86821e251fccc82a2eefbfc4db7605e#cli-portable --no-link --print-out-paths 2>/dev/null | tail -1)/bin/lgpm"
[ -x "$L" ] && [ -x "$LGPM" ] || { echo "logoscore or lgpm did not build"; exit 1; }

PORT=${ANVIL_PORT:-18591}
PW="muster-r4-test-only"
KEY_A=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil 0
ADDR_A=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
KEY_B=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d   # anvil 1
ADDR_B=0x70997970c51812dc3a010c7d01b50e0d17dc79c8
D=$(mktemp -d)

ANVIL=$(nix build nixpkgs#foundry --no-link --print-out-paths 2>/dev/null | tail -1)/bin/anvil
CAST=$(dirname "$ANVIL")/cast
setsid "$ANVIL" --port "$PORT" --chain-id 31337 --block-time 1 >"$D/anvil.log" 2>&1 &
for _ in $(seq 1 30); do "$CAST" chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 1; done

PIDS=()
start() {   # $1 = name, $2 = delivery config
  local n=$1
  mkdir -p "$D/$n/cfg" "$D/$n/data"
  cp -rL --no-preserve=mode "$PROFILE/modules" "$D/$n/mods"
  for x in evm_keystore_cli evm_signer_cli; do
    "$LGPM" --modules-dir "$D/$n/mods" --ui-plugins-dir "$D/$n/plugins" --allow-unsigned install --file "$CLI/$x.lgx" >/dev/null
  done
  MUSTER_LP_DEBUG=1 MUSTER_DATA_DIR="$D/$n/data" MUSTER_DELIVERY_CONFIG="$2" \
    setsid "$L" --config-dir "$D/$n/cfg" daemon -m "$D/$n/mods" --persistence-path "$D/$n/cfg/data" >"$D/$n.log" 2>&1 &
  PIDS+=($!)
}
c() { local n=$1; shift; timeout 90 "$L" --config-dir "$D/$n/cfg" "$@" 2>&1 | tail -1; }
res() { python3 -c 'import sys,json
try:
  r=json.load(sys.stdin)["result"]; print(r if isinstance(r,str) else json.dumps(r))
except Exception: print("")'; }
j() { python3 -c "import sys,json
try: d=json.loads(sys.stdin.read())
except Exception: d={}
print($1)"; }
cleanup() {
  for n in a b; do c "$n" stop >/dev/null; done
  for p in "${PIDS[@]}"; do kill -9 -"$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
  pkill -f "anvil --port $PORT" 2>/dev/null
  [ -n "${KEEP_LOGS:-}" ] && echo "logs: $D" || rm -rf "$D"
}
trap cleanup EXIT
ok=1
step() { echo "── $*"; }
fail() { echo "FAIL: $*"; ok=0; }

HUB=$(ui_local_config)
start a "$HUB"
for _ in $(seq 1 30); do c a status >/dev/null && break; sleep 1; done
for m in muster_module evm_keystore_cli evm_signer_cli; do c a load-module "$m" >/dev/null; done

approve() {   # $1 = instance, $2 = handle: what a person does in the signer
  c "$1" call evm_signer_cli refresh >/dev/null
  local show bid
  show=$(c "$1" call evm_signer_cli show "$2" | res)
  echo "$show" | python3 -c 'import sys,json
s=json.load(sys.stdin); print("   " + "\n   ".join((s.get("text") or json.dumps(s))[:1600].splitlines()[:16]))' 2>/dev/null
  bid=$(echo "$show" | j 'd.get("bundle_id","")')
  c "$1" call evm_signer_cli approve "$2" "$bid" "$PW" | res | cut -c1-160
}

setup() {   # $1 = instance: the person's chain, key, account and its link
  local n=$1
  key=$KEY_A; local addr=$ADDR_A; [ $n = b ] && { key=$KEY_B; addr=$ADDR_B; }
  step "$n: the person's chain (eth_rpc_ui) and key (evm_keystore_ui)"
  c $n call eth_rpc_module init_defaults >/dev/null
  c $n call eth_rpc_module set_chain_config 31337 "{\"endpoint\":\"http://127.0.0.1:$PORT\"}" >/dev/null
  c $n call eth_rpc_module patch_chain_metadata 31337 '{"name":"anvil","nativeSymbol":"ETH","nativeDecimals":18,"testnet":true}' >/dev/null
  c $n call eth_rpc_module set_chain_enabled 31337 true >/dev/null
  c $n call keystore_module configure '{"approvers":["evm_signer_ui","evm_signer_cli"],"custodians":["evm_keystore_ui","evm_keystore_cli"]}' >/dev/null
  c $n call evm_keystore_cli import_private_key "$key" "$PW" | res | cut -c1-100
  c $n call muster_module settings >/dev/null
  for _ in 1 2 3; do c $n call muster_module keystore_status >/dev/null; sleep 2; done
  step "$n: select the account; link it to the room identity in the signer"
  SEL=$(c $n call muster_module keystore_select "$addr" | res); echo "   $SEL" | cut -c1-160
  H=$(echo "$SEL" | j 'd.get("handle","")')
  [ -n "$H" ] || fail "$n: no binding request"
  approve $n "$H" >/dev/null
  b=""
  for _ in $(seq 1 30); do
    c $n call muster_module keystore_requests >/dev/null
    b=$(c $n call muster_module keystore_status | res | j 'd.get("binding","")')
    [ "$b" = valid ] && break; sleep 2
  done
  echo "   binding: $b"; [ "$b" = valid ] || fail "$n: binding never valid"
}

TOPIC="/muster/1/r4-$(date +%s)/proto"
setup a
step "room: Alice opens (her delivery node starts), Bob joins it and asks, Alice admits"
c a call muster_module coordinate_join "$TOPIC" >/dev/null
PEER=$(ui_peer_config "$D/a.log") || { echo "Alice's node never started"; exit 1; }
start b "$PEER"
for _ in $(seq 1 30); do c b status >/dev/null && break; sleep 1; done
for m in muster_module evm_keystore_cli evm_signer_cli; do c b load-module "$m" >/dev/null; done
setup b
c b call muster_module coordinate_join "$TOPIC" >/dev/null
BOBID=""
for _ in $(seq 1 30); do
  c b call muster_module coordinate_request_join >/dev/null
  c a call muster_module coordinate_intents >/dev/null
  BOBID=$(c a call muster_module coordinate_pending | res | j '(d[0].get("identity","") if isinstance(d,list) and d else "").lower()')
  [ -n "$BOBID" ] && break; sleep 2
done
[ -n "$BOBID" ] || { fail "Bob's join request never reached Alice"; exit 1; }
c a call muster_module coordinate_admit "$BOBID" >/dev/null
for _ in $(seq 1 30); do
  for n in a b; do c $n call muster_module coordinate_intents >/dev/null; done   # the UI's tick: polls the room
  nb=$(c b call muster_module coordinate_members | res | j 'len(d) if isinstance(d,list) else 0')
  [ "$nb" = 2 ] && break; sleep 2
done
echo "   members (Bob's view): $nb"; [ "$nb" = 2 ] || fail "Bob never saw two members"

step "Alice proposes: 0.002 ETH on eip155:31337, Bob owes half"
P=$(c a call muster_module coordinate_propose_split eip155:31337 str:2000000000000000 "[\"$BOBID\"]" "anvil dinner" | res); echo "   $P" | cut -c1-200
ID=$P; case "$ID" in 0x*) ;; *) fail "no split proposed"; exit 1 ;; esac
PAYTO=$(c a call muster_module coordinate_intents | res | j "next(((i.get('effect') or {}).get('payTo','') for i in d if i.get('id')=='$ID'), '')")
echo "   payTo: $PAYTO (Alice's keystore account: $ADDR_A)"
[ "$(echo "$PAYTO" | tr A-F a-f)" = "$ADDR_A" ] || fail "the split is not paid at Alice's keystore account"

step "Bob agrees"
for _ in $(seq 1 30); do
  st=$(c b call muster_module coordinate_intents | res | j "next((i.get('state') for i in d if i.get('id')=='$ID'), '')")
  [ -n "$st" ] && break; sleep 2
done
c b call muster_module coordinate_contribute "$ID" "" "" | res
for _ in $(seq 1 30); do
  st=$(c b call muster_module coordinate_intents | res | j "next((i.get('state') for i in d if i.get('id')=='$ID'), '')")
  [ "$st" = executable ] && break; sleep 2
done
echo "   state: $st"; [ "$st" = executable ] || fail "the split never became agreed"

BAL0=$("$CAST" balance "$ADDR_A" --rpc-url "http://127.0.0.1:$PORT")
step "Bob pays: through tx_sender_module, one approval in the signer"
PAY=$(c b call muster_module coordinate_settle_part "$ID" | res); echo "   $PAY"
echo "$PAY" | grep -q '"pending":"txs:' || fail "the payment did not go through tx_sender_module"
SH=""
for _ in $(seq 1 15); do
  SH=$(c b call muster_module keystore_requests | res | j "next((r['handle'] for r in d.get('requests',[]) if r.get('kind')=='send' and r.get('state')=='waiting'), '')")
  [ -n "$SH" ] && break; sleep 1
done
echo "   signer handle: $SH"; [ -n "$SH" ] || fail "no send waiting in the signer"
approve b "$SH"

step "the broadcast, Bob's report, Alice's own read, final"
fa=""; fb=""
for _ in $(seq 1 60); do
  fb=$(c b call muster_module coordinate_intents | res | j "next((i.get('state') for i in d if i.get('id')=='$ID'), '')")
  fa=$(c a call muster_module coordinate_intents | res | j "next((i.get('state') for i in d if i.get('id')=='$ID'), '')")
  [ "$fa" = final ] && [ "$fb" = final ] && break; sleep 2
done
echo "   Alice: $fa   Bob: $fb"
[ "$fa" = final ] && [ "$fb" = final ] || fail "the split did not go final on both"
BAL1=$("$CAST" balance "$ADDR_A" --rpc-url "http://127.0.0.1:$PORT")
GOT=$(python3 -c "print($BAL1 - $BAL0)")
echo "   Alice received $GOT wei"
[ "$GOT" = 1000000000000000 ] || fail "Alice should have received exactly the share (1000000000000000)"
SENT=$(c b call tx_sender_module history "$ADDR_B" 31337 | res | j "[(t.get('hash','')[:12], t.get('origin',''), (t.get('meta') or {}).get('muster',{}).get('intent','')[:12]) for t in d.get('transactions',[])][:3]")
echo "   tx_sender history (Bob): $SENT"

if [ $ok = 1 ]; then echo "PASS split-platform-logoscore-test"; exit 0; fi
echo "FAIL split-platform-logoscore-test"
grep -a -h "MUSTER-LP split\|MUSTER-LP keystore-requests" "$D"/b.log 2>/dev/null | tail -6 | cut -c1-300
KEEP_LOGS=1; exit 1
