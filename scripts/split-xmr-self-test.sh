#!/usr/bin/env bash
# A Monero payment request through the real UI binary (exo-dcc.5) — no GUI, no clicks, and
# NO Monero wallet: the runner bundles no monero_wallet_backend. Two offscreen runners:
#   A founds a room, admits B, and once B is in chooses the "Split (Monero)" kind bare
#     (MUSTER_AUTOPOLICY=monero-split — the "Settles on" button) and requests
#     0.123456789012 XMR of B with no chain named (MUSTER_AUTOSPLIT — the slot the Split
#     composer's Propose calls under the "Request" kind);
#   B says "I paid" for a request that does not exist (MUSTER_AUTOREPORTPAID — the slot the
#     card's "I paid" calls).
# Passes when
#   * the bare kind is taken on Monero stagenet, never the EVM RPC's chain;
#   * A's module refuses the request BEFORE minting anything, with a wallet error that names
#     both remedies the composer offers: request monero.wallet.unlock (Open Monero Wallet)
#     and install monero_wallet_ui (Install);
#   * no request reaches the room (neither instance folds a split);
#   * B's "I paid" reaches coordinate_report_paid, which refuses the unknown request.
#
# What this cannot prove without a wallet: the mint of payTo, B's agreement, the monero:
# link and QR on B's card, the report on a real request, and A's wallet confirming at 10
# confirmations. Those are held by the module's probes over a recording fake backend
# (docs/labbook/xmr-payment-request.md) and, for the QML, by an offscreen harness; a live
# stagenet run needs Basecamp with the Monero stack and a funded stagenet wallet.
#
#   make build && scripts/split-xmr-self-test.sh        # KEEP_LOGS=1 keeps the logs
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner

STAGENET="monero:76ee3cc98646292206cd3e86f74d88b4"
TOTAL=123456789012
FAKE_ID=0x$(printf 'ab%.0s' $(seq 1 32))
CFG=$(ui_fleet_config)
TOPIC="/muster/1/split-xmr-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC · logs: $D"
trap ui_cleanup EXIT

common=(MUSTER_LP_DEBUG=1 MUSTER_AUTOJOIN_TOPIC="$TOPIC" QT_FORCE_STDERR_LOGGING=1)
ui_launch "$D/A" "$D/A.log" "${common[@]}" MUSTER_DELIVERY_CONFIG="$CFG" LOGOS_INSTANCE_ID=xmrA \
  MUSTER_AUTOADMIT=1 MUSTER_AUTOSPLIT="$TOTAL" MUSTER_AUTOPOLICY=monero-split
CFG=$(ui_peer_config "$D/A.log") || exit 1
ui_launch "$D/B" "$D/B.log" "${common[@]}" MUSTER_DELIVERY_CONFIG="$CFG" LOGOS_INSTANCE_ID=xmrB \
  MUSTER_AUTOREPORTPAID="$FAKE_ID"

refused() { grep -aE 'MUSTER-LP split propose \{' "$D/A.log" 2>/dev/null | tail -1; }
echo "watching for A's request to be answered (up to 150s)..."
for i in $(seq 1 150); do
  sleep 1
  [ -n "$(refused)" ] && break
done
sleep 5   # let both folds run a few ticks: a request that did land would show by now

line=$(refused)
report=$(grep -aE "MUSTER-LP split report-paid $FAKE_ID" "$D/B.log" | tail -1)
echo "A: ${line:-<no answer>}"
echo "B: ${report:-<no report line>}"
ok=1
python3 - "$line" <<'EOF' || ok=0
import json, sys
line = sys.argv[1]
j = json.loads(line[line.index("{"):]) if "{" in line else {}
wallet = {"no-wallet", "wallet-unread", "wallet-busy", "wallet-other-network", "wallet-watch-only"}
checks = [("refused with a wallet error", j.get("error") in wallet),
          ("names monero.wallet.unlock", j.get("request") == "monero.wallet.unlock"),
          ("names monero_wallet_ui to install", j.get("install") == "monero_wallet_ui")]
for name, good in checks: print(("  ok   " if good else "  FAIL ") + name, "" if good else j)
sys.exit(0 if all(g for _, g in checks) else 1)
EOF
pol=$(grep -a 'AUTOPOLICY ->' "$D/A.log" | tail -1)
if echo "$pol" | grep -q "monero-split@$STAGENET"; then echo "  ok   the bare kind is taken on Monero stagenet"
else echo "  FAIL the bare kind: ${pol:-no AUTOPOLICY line}"; ok=0; fi
if grep -aqE 'MUSTER-LP split 0x[0-9a-f]+ state=' "$D/A.log" "$D/B.log"; then
  echo "  FAIL a split reached the room"; ok=0
else echo "  ok   no request reached the room"; fi
if echo "$report" | grep -qE '"error":"(unknown-intent|not-a-monero-request)"'; then
  echo "  ok   B's \"I paid\" reached coordinate_report_paid and was refused"
else echo "  FAIL B's \"I paid\" answer: ${report:-none}"; ok=0; fi
grep -aq 'members=2' "$D/A.log" && echo "  ok   both in the room" || echo "  (A never logged members=2)"

if [ "$ok" = 1 ]; then
  echo "SUCCESS: the request was refused for want of a wallet, naming both remedies; I paid reaches the module."
  [ -n "${KEEP_LOGS:-}" ] && echo "logs kept in $D" || rm -rf "$D"
else
  echo "FAIL — logs kept in $D"
  exit 1
fi
