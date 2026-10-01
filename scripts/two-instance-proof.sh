#!/usr/bin/env bash
# Proof that two muster instances converge over the Logos fleet (or, with
# MUSTER_FLEET=local, a network of their own on this host) — no GUI, no manual steps.
# Launches two offscreen runners auto-joined to ONE topic (A is the founder and
# auto-admits), and passes when BOTH report members=2: B's join request crossed to A,
# A admitted it, and the re-key grant crossed back. Exits non-zero otherwise, keeping
# both logs. (A's pending=1 is only transient under auto-admit — it drops to 0 on the
# admit — so it is reported, not asserted.)
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
TOPIC="/muster/1/proof-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC"
ui_launch "$D/A" "$D/A.log" \
  MUSTER_AUTOADMIT=1 MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=proofA
CFG_B=$(ui_peer_config "$D/A.log") || exit 1
ui_launch "$D/B" "$D/B.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG_B" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=proofB
echo "two instances launched; watching for both to reach members=2 (up to 60s)..."
both() { grep -aqE 'members=2' "$D/A.log" 2>/dev/null && grep -aqE 'members=2' "$D/B.log" 2>/dev/null; }
ok=0
for i in $(seq 1 60); do
  sleep 1
  both && { ok=1; break; }
done
ui_cleanup
saw() { grep -aqE "$1" "$2" 2>/dev/null && echo yes || echo no; }
echo "A saw the join request (pending=1): $(saw 'pending=1' "$D/A.log") · A members=2: $(saw 'members=2' "$D/A.log") · B members=2: $(saw 'members=2' "$D/B.log")"
if [ "$ok" = 1 ]; then
  echo "SUCCESS: both instances at members=2 after ~${i}s — the handshake crossed $MUSTER_FLEET both ways."
  rm -rf "$D"
else
  echo "FAIL: not converged in 60s — createNode: $(grep -aoE 'createNode result=[^ ]{0,20}' "$D/A.log"|tail -1); logs kept in $D"
  exit 1
fi
