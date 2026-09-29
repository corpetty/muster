#!/usr/bin/env bash
# A split, end to end through the real UI binary (exo-a90.6/.8) — no GUI, no clicks. Two
# offscreen runners on the Logos fleet and a throwaway anvil:
#   A (seeded as anvil account 0) founds a room, admits B, and once B is in proposes
#     splitting 0.6 ETH it fronted (MUSTER_AUTOSPLIT — the Split composer's slot);
#   B (anvil account 1) agrees to its 0.3 ETH share, then pays it from its own wallet
#     (MUSTER_AUTOPAYSPLIT — "Agree to my share", then "Pay my share");
#   A's client confirms the payment from its OWN RPC read (the module's pump).
# Passes when both instances log the split final and A's balance rose by exactly B's
# share. Both runners use MUSTER_RPC=<the throwaway anvil>, never a chain you run.
#
# SPLIT_ON_BEHALF=1 turns it around (exo-770): B fronted the bill and shares its address
# into the room (MUSTER_AUTOSHARE); A proposes the split on B's behalf, paid at the
# address B shared (MUSTER_AUTOSPLIT_FOR); B's client agrees as the creditor only
# because it holds that address; A pays its share; B's own read confirms it. Passes when
# both log final and B's balance rose by exactly A's share.
#
# What this proves, and what it does not: the backend slots the Split composer and the
# card call (proposeSplit / contributeInRoom / settlePart), the module, the fleet and the
# chain, in the real runner. Offscreen, the QML view is never instantiated
# (docs/labbook/qml-errors-are-invisible-to-nix-build.md), so a clean log says nothing
# about the QML: lint it with the design system on the import path, and look at the window.
#
#   make build && scripts/split-self-test.sh        # SPLIT_ANVIL_PORT (default 8551), KEEP_LOGS=1
#
# Cleanup kills only this script's own processes (each runner's session), never another
# muster you may have running.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
command -v anvil >/dev/null && command -v cast >/dev/null || { echo "needs foundry (anvil, cast)"; exit 1; }

PORT="${SPLIT_ANVIL_PORT:-8551}"
RPC="http://127.0.0.1:$PORT"
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "something already answers on $PORT — set SPLIT_ANVIL_PORT to a free port"; exit 1
fi
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil account 0
KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d   # anvil account 1
ADDR0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADDR1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ONBEHALF="${SPLIT_ON_BEHALF:-}"
PAYEE=$([ -n "$ONBEHALF" ] && echo "$ADDR1" || echo "$ADDR0")   # who is paid: the creditor
TOTAL=600000000000000000   # 0.6 ETH: A's own share 0.3, B owes 0.3
SHARE=300000000000000000
CFG=$(python3 -c 'import json;print(json.dumps(json.load(open("infra/fleets/logos.test.json"))["delivery_createNode_config"]))')
TOPIC="/muster/1/split-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC · anvil: $RPC · logs: $D"

anvil --port "$PORT" --silent >"$D/anvil.log" 2>&1 &
APID=$!
disown $APID
for _ in $(seq 1 20); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.5; done
BEFORE=$(cast balance "$PAYEE" --rpc-url "$RPC")

launch() {  # name, extra env… — each runner in its own session, so cleanup can find it
  local name="$1"; shift
  env "$@" MUSTER_RPC="$RPC" MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" \
      MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID="split$name" QT_QPA_PLATFORM=offscreen \
      setsid "$RUNNER" --user-dir "$D/$name" >"$D/$name.log" 2>&1 &
  echo $! >"$D/$name.pid"
  disown $!
}
if [ -n "$ONBEHALF" ]; then
  echo "on B's behalf: B shares its address, A proposes for B and pays; B agrees as creditor and confirms"
  launch A MUSTER_DEV_SECP_KEY="$KEY0" MUSTER_AUTOADMIT=1 MUSTER_AUTOSPLIT="$TOTAL" MUSTER_AUTOSPLIT_FOR=1 MUSTER_AUTOPAYSPLIT=1
  sleep 3
  launch B MUSTER_DEV_SECP_KEY="$KEY1" MUSTER_AUTOSHARE=1 MUSTER_AUTOPAYSPLIT=1
else
  launch A MUSTER_DEV_SECP_KEY="$KEY0" MUSTER_AUTOADMIT=1 MUSTER_AUTOSPLIT="$TOTAL"
  sleep 3
  launch B MUSTER_DEV_SECP_KEY="$KEY1" MUSTER_AUTOPAYSPLIT=1
fi

cleanup() {
  for n in A B; do
    local pid sid
    pid=$(cat "$D/$n.pid" 2>/dev/null) || continue
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$sid" ] && pkill -9 -s "$sid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
  done
  kill "$APID" 2>/dev/null
}
trap cleanup EXIT

final() { grep -aqE 'MUSTER-LP split [0-9a-fx]+ state=final' "$D/$1.log" 2>/dev/null; }
echo "watching for the split to reach final on both instances (up to 180s)..."
ok=0
for i in $(seq 1 180); do
  sleep 1
  final A && final B && { ok=1; break; }
done

saw() { grep -aqE "$1" "$D/$2.log" 2>/dev/null && echo yes || echo no; }
if [ -n "$ONBEHALF" ]; then P=A; C=B; else P=B; C=A; fi   # the payer and the creditor
echo "A members=2: $(saw 'members=2' A) · A proposed: $(saw 'MUSTER-LP split propose 0x' A)" \
     "· $P paid: $(saw 'MUSTER-LP split pay .*pending' $P) · $P reported: $(saw 'MUSTER-LP split reported' $P)" \
     "· $C confirmed: $(saw 'MUSTER-LP split confirmed' $C)"
grep -ahE 'MUSTER-LP split ' "$D/A.log" | tail -6 | sed 's/^/  A │ /'
grep -ahE 'MUSTER-LP split ' "$D/B.log" | tail -6 | sed 's/^/  B │ /'

AFTER=$(cast balance "$PAYEE" --rpc-url "$RPC")
GAIN=$(python3 -c "print(int('$AFTER') - int('$BEFORE'))")
if [ "$ok" = 1 ] && [ "$GAIN" = "$SHARE" ]; then
  echo "SUCCESS after ~${i}s: final on both instances; $C received exactly $P's share ($GAIN wei)."
  cleanup; trap - EXIT
  [ -n "${KEEP_LOGS:-}" ] && echo "logs kept in $D" || rm -rf "$D"
else
  echo "FAIL: final on both=$ok, $C gained $GAIN wei (want $SHARE) — logs kept in $D"
  exit 1
fi
