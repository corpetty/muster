#!/usr/bin/env bash
# The private split, end to end on the LEZ testnet (exo-a90.9 / exo-14d) — no GUI, no
# clicks. Two offscreen runners on the Logos fleet, each with its OWN real LEZ wallet
# (MUSTER_LEZ_REAL, lez_core against testnet.lez.logos.co):
#   B funds its private balance the way a person would: native LEZ arrives at its public
#     account from someone who holds some, then a shield of what arrived to its OWN key
#     node (MUSTER_AUTOLEZFUND) — a proof of minutes; the note lands at an account B's
#     scan discovers;
#   A (the founder) admits B and proposes a private split of LEZ_SPLIT_TOTAL base units,
#     paid at A's shielded key node (MUSTER_AUTOSPLIT + MUSTER_AUTOSPLIT_CHAIN);
#   B agrees, then — once funded — pays its share shielded → shielded from the note that
#     covers it (MUSTER_AUTOPAYSPLIT) — another proof;
#   A's own scan finds a note of exactly B's share at its key node and confirms it.
# Passes when both instances log the split final and A confirmed B's part by a note hash.
#
# NOT RUNNABLE AS IS on the v0.3 testnet (exo-eb6.4): LEZ v0.3.0 removed the faucet, so B
# waits at "LEZFUND awaiting funds at <account>" until someone who holds native LEZ sends
# to it, and muster's private rails are unverified against v0.3's 256-bit private ids
# (exo-357). It last passed on the v0.2.4 testnet, 2026-09-28.
#
# What the chain learns: that private transfers happened — no payer, payee or amount. The
# run prints B's payment transaction so it can be looked up on the explorer.
#
#   make build && scripts/split-lez-testnet.sh
#     LEZ_SPLIT_TOTAL   the bill, base units (default 100 — B owes about half)
#     LEZ_SPLIT_STATE   where the two LEZ wallets live between runs (default .run/lez-split):
#                       kept, so a re-run skips the scan from block 0 and B's funding stays
#     LEZ_SPLIT_TIMEOUT seconds to wait (default 2700: B's funding, two proofs, two scans)
#     LEZ_SPLIT_FUND=0  skip B's funding: re-run over wallets a previous run funded (B pays
#                       from the change its shielded note kept) — one proof, and the run
#                       relaunches over wallets whose accounts are labelled (exo-884)
#     KEEP_LOGS=1       keep the runners' logs on success too
#
# This spends testnet LEZ that B was funded with and sends two private transfers on the
# public testnet. Cleanup kills only this script's own processes (each runner's session).
set -uo pipefail
# One compound command: bash reads it whole before running any of it, so editing this file
# while a run is under way cannot change the running copy (a run died that way, 2026-09-28).
{
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
curl -s -m 10 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getLastBlockId","params":[]}' https://testnet.lez.logos.co \
  | grep -q '"result"' || { echo "testnet.lez.logos.co does not answer"; exit 1; }

TOTAL="${LEZ_SPLIT_TOTAL:-100}"
STATE="${LEZ_SPLIT_STATE:-.run/lez-split}"
TIMEOUT="${LEZ_SPLIT_TIMEOUT:-2700}"
mkdir -p "$STATE/A" "$STATE/B"
STATE=$(cd "$STATE" && pwd)
CFG=$(ui_fleet_config)
TOPIC="/muster/1/split-lez-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC · LEZ wallets: $STATE · logs: $D · total: $TOTAL"

launch() {  # name, extra env… — each runner in its own session, so cleanup can find it
  local name="$1"; shift
  env "$@" MUSTER_LEZ_REAL=1 MUSTER_DATA_DIR="$STATE/$name" MUSTER_LP_DEBUG=1 \
      MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID="splitlez$name" \
      QT_QPA_PLATFORM=offscreen setsid "$RUNNER" --user-dir "$D/$name" >"$D/$name.log" 2>&1 &
  echo $! >"$D/$name.pid"
  disown $!
}
launch A MUSTER_AUTOADMIT=1 MUSTER_AUTOSPLIT="$TOTAL" MUSTER_AUTOSPLIT_CHAIN=lez:testnet
sleep 3
if [ "${LEZ_SPLIT_FUND:-1}" = 0 ]; then launch B MUSTER_AUTOPAYSPLIT=1
else launch B MUSTER_AUTOPAYSPLIT=1 MUSTER_AUTOLEZFUND=1
fi

cleanup() {
  for n in A B; do
    local pid sid
    pid=$(cat "$D/$n.pid" 2>/dev/null) || continue
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$sid" ] && pkill -9 -s "$sid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
  done
}
trap cleanup EXIT

final() { grep -aqE 'MUSTER-LP split [0-9a-fx]+ state=final' "$D/$1.log" 2>/dev/null; }
last() { grep -ahE "$1" "$D/$2.log" 2>/dev/null | tail -1 | cut -c1-160; }
echo "watching for the split to reach final on both instances (up to ${TIMEOUT}s)..."
ok=0
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ]; do
  sleep 5
  final A && final B && { ok=1; break; }
  if [ $(( ($(date +%s) - start) % 60 )) -lt 5 ]; then
    echo "[$(( $(date +%s) - start ))s] B: $(last 'MUSTER-LP (wallet_lez_setup|wallet_send|wallet_finality|split (pay|reported))' B)"
    echo "        A: $(last 'MUSTER-LP split|MUSTER-LEZ scan' A)"
  fi
done
elapsed=$(( $(date +%s) - start ))

saw() { grep -aqE "$1" "$D/$2.log" 2>/dev/null && echo yes || echo no; }
echo "A members=2: $(saw 'members=2' A) · A proposed: $(saw 'MUSTER-LP split propose 0x' A)" \
     "· B funded: $( [ "${LEZ_SPLIT_FUND:-1}" = 0 ] && echo "skipped (LEZ_SPLIT_FUND=0)" || saw 'MUSTER-LP wallet_finality lez:testnet .*"final"' B) · B paid: $(saw 'MUSTER-LP split pay .*pending' B)" \
     "· B reported: $(saw 'MUSTER-LP split reported' B) · A confirmed: $(saw 'MUSTER-LP split confirmed' A)"
# (the UI backend's own log lines do not reach the runner's log; the module's MUSTER-LP ones do)
grep -ahE 'MUSTER-LP (wallet_lez_setup|wallet_send|wallet_finality)' "$D/B.log" | tail -5 | cut -c1-220 | sed 's/^/  B │ /'
grep -ahE 'MUSTER-LP split |MUSTER-LEZ' "$D/A.log" | tail -6 | cut -c1-220 | sed 's/^/  A │ /'
grep -ahE 'MUSTER-LP split |MUSTER-LEZ' "$D/B.log" | tail -6 | cut -c1-220 | sed 's/^/  B │ /'

if [ "$ok" = 1 ] && grep -aqE 'MUSTER-LP split [0-9a-fx]+ state=final .*refs=.*note:' "$D/A.log"; then
  echo "SUCCESS after ~${elapsed}s: final on both instances; A's own scan confirmed B's share by a note hash."
  echo "B's payment on the zone: $(grep -ahoE 'MUSTER-LP split reported .* tx=[^ ]+' "$D/B.log" | tail -1 | sed 's/.* tx=//')"
  echo "A's confirmation: $(grep -ahoE 'state=final .*refs=[^ ]+' "$D/A.log" | tail -1 | sed 's/.*refs=//')"
  cleanup; trap - EXIT
  [ -n "${KEEP_LOGS:-}" ] && echo "logs kept in $D" || rm -rf "$D"
else
  echo "FAIL after ${elapsed}s: final on both=$ok — logs kept in $D (LEZ wallets in $STATE)"
  exit 1
fi
exit
}
