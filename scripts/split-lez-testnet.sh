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
# v0.3 has no faucet (exo-eb6.4): when B's setup names the account it needs funded, the
# zone's FUNDER sends to it (infra/lez/funder.sh). On the testnet that is the one account
# someone holding native LEZ funded (`infra/lez/funder.sh --zone testnet account`); while it
# cannot cover B's funding, B waits at "LEZFUND awaiting funds at <account>" for anyone to
# send to it. The testnet run last passed on v0.2.4, 2026-09-28. LEZ_SPLIT_ZONE=local runs
# it on a local v0.3.0 zone instead (infra/lez/localnet.sh, started if it is not up), whose
# genesis funder is the zone's funder; the wallets start fresh (a new local chain knows none
# of the old ones), and proofs are dev-mode receipts the local sequencer accepts
# (LEZ_SPLIT_PROVE=1 proves for real). Private transactions are fee-exempt on v0.3.
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
#     LEZ_SPLIT_ZONE    testnet (default) or local (a local v0.3.0 zone, funded by its funder)
#     LEZ_SPLIT_FUND_AMOUNT  what the zone's funder sends B (default 1000 base units)
#     LEZ_SPLIT_PROVE=1 on the local zone, prove for real instead of dev-mode receipts
#     KEEP_LOGS=1       keep the runners' logs on success too
#   MUSTER_FLEET=local runs the two runners' delivery on a network of their own, too.
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
ZONE="${LEZ_SPLIT_ZONE:-testnet}"
case "$ZONE" in
  testnet) URL="https://testnet.lez.logos.co"; DEFSTATE=.run/lez-split; ZONE_ENV=() ;;
  local)   URL="http://127.0.0.1:3040"; DEFSTATE=.run/lez-split-local
           infra/lez/localnet.sh >/dev/null || { echo "the local LEZ zone did not start"; exit 1; }
           ZONE_ENV=(MUSTER_LEZ_RPC="$URL")
           [ -n "${LEZ_SPLIT_PROVE:-}" ] || ZONE_ENV+=(RISC0_DEV_MODE=1) ;;
  *) echo "LEZ_SPLIT_ZONE is testnet or local, not '$ZONE'"; exit 2 ;;
esac
curl -s -m 10 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getLastBlockId","params":[]}' "$URL" \
  | grep -q '"result"' || { echo "$URL does not answer"; exit 1; }

TOTAL="${LEZ_SPLIT_TOTAL:-100}"
STATE="${LEZ_SPLIT_STATE:-$DEFSTATE}"
TIMEOUT="${LEZ_SPLIT_TIMEOUT:-2700}"
FUNDED=0
if [ "$ZONE" = local ] && [ "${LEZ_SPLIT_FUND:-1}" != 0 ]; then
  rm -rf "$STATE/A" "$STATE/B"        # a fresh local chain knows none of the old wallets
fi
mkdir -p "$STATE/A" "$STATE/B"
STATE=$(cd "$STATE" && pwd)
CFG=$(ui_fleet_config)
TOPIC="/muster/1/split-lez-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC · LEZ zone: $ZONE ($URL) · LEZ wallets: $STATE · logs: $D · total: $TOTAL"

launch() {  # name, extra env… — each runner in its own session, so cleanup can find it
  local name="$1"; shift
  env "$@" "${ZONE_ENV[@]}" MUSTER_LEZ_REAL=1 MUSTER_DATA_DIR="$STATE/$name" MUSTER_LP_DEBUG=1 \
      MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID="splitlez$name" \
      QT_QPA_PLATFORM=offscreen setsid "$RUNNER" --user-dir "$D/$name" >"$D/$name.log" 2>&1 &
  echo $! >"$D/$name.pid"
  disown $!
}
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

launch A MUSTER_AUTOADMIT=1 MUSTER_AUTOSPLIT="$TOTAL" MUSTER_AUTOSPLIT_CHAIN=lez:testnet
CFG=$(ui_peer_config "$D/A.log") || exit 1
if [ "${LEZ_SPLIT_FUND:-1}" = 0 ]; then launch B MUSTER_AUTOPAYSPLIT=1
else launch B MUSTER_AUTOPAYSPLIT=1 MUSTER_AUTOLEZFUND=1
fi

final() { grep -aqE 'MUSTER-LP split [0-9a-fx]+ state=final' "$D/$1.log" 2>/dev/null; }
last() { grep -ahE "$1" "$D/$2.log" 2>/dev/null | tail -1 | cut -c1-160; }
echo "watching for the split to reach final on both instances (up to ${TIMEOUT}s)..."
ok=0
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ]; do
  sleep 5
  final A && final B && { ok=1; break; }
  # no faucet on v0.3: once B's own setup names the account it needs funded (its module's
  # wallet_lez_setup line), the zone's funder sends to it, once — when it can cover it
  if [ "$FUNDED" = 0 ] && [ "${LEZ_SPLIT_FUND:-1}" != 0 ]; then
    acct=$(grep -ahoE 'MUSTER-LP wallet_lez_setup \{"account":"[0-9a-f]{64}","state":"missing"' "$D/B.log" 2>/dev/null \
           | head -1 | grep -oE '[0-9a-f]{64}')
    if [ -n "$acct" ]; then
      amount="${LEZ_SPLIT_FUND_AMOUNT:-1000}"
      held=$(infra/lez/funder.sh --zone "$ZONE" balance 2>/dev/null || echo unknown)
      if [[ "$held" =~ ^[0-9]+$ ]] && [ "$held" -ge $(( amount + 134400000 )) ]; then
        echo "[$(( $(date +%s) - start ))s] the zone's funder sends B $amount at $acct"
        infra/lez/funder.sh --zone "$ZONE" fund "$acct" "$amount" >/dev/null 2>&1 \
          && FUNDED=1 || echo "  the funder could not send (retrying)"
      elif [ -z "${WARNED:-}" ]; then
        WARNED=1
        echo "[$(( $(date +%s) - start ))s] the zone's funder holds $held, not enough to fund B: fund it" \
             "($(infra/lez/funder.sh --zone "$ZONE" account 2>/dev/null | sed 's/ holding.*//')), or send to B at $acct"
      fi
    fi
  fi
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
