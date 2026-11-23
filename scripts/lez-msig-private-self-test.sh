#!/usr/bin/env bash
# A PRIVATE lez-msig on LEZ v0.4 through the real UI binary (exo-05f, exo-cc7): two offscreen
# runners in one room, the prover lez_msig_module 0.2.0 in the runner's module set, the program
# deployed immutable on a local LEZ v0.4.0-rc3 zone. No GUI, no clicks: the backend's autopilot
# calls the slots the accounts panel and the card call.
#   A founds the room, admits B, and once B is in opens a private 2-of-2 (MUSTER_AUTOMSIG_OPEN,
#   MUSTER_AUTOMSIG_PRIVATE): the group secret is sealed to each member;
#   A tops up the group's fee account through the ceremony's create key (MUSTER_AUTOMSIG_TOPUP,
#   the panel's "Top up the fee account"): on v0.4 every private transaction pays its fee from it,
#   and Create waits for it;
#   A's module creates it through the prover and discloses it; A deposits from its own account
#   (MUSTER_AUTOMSIG_FUND); A proposes a payment to a public payee (MUSTER_AUTOMSIG_PAY), B approves
#   on the card, A settles: one privacy-preserving transaction, its fee from the fee account.
# Passes when the payee holds exactly the payment and both runners fold the intent final. The payee
# is a fresh account of the funder's wallet (funder.sh new-account), since v0.4 admits a fresh
# public account only by its key.
#
#   MUSTER_LEZ_VERSION=v0.4.0-rc3 infra/lez/localnet.sh
#   make build                                            # the runner holds both provers (exo-cc7)
#   scripts/lez-msig-private-self-test.sh
#   MSIG_PROGRAM (skip the deploy of lez04's artifacts/msig.bin), LEZ_RPC (default
#   http://127.0.0.1:3040), KEEP_LOGS=1, MUSTER_FLEET=local (no fleet). Dev-mode proofs: the local
#   zone runs RISC0_DEV_MODE, and so do the runners here. On the devnet: MSIG_REAL_PROOFS=1 (the
#   runners prove for real) and MSIG_WAIT_S (default 900) for four proofs and minute-long blocks.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT

RPC="${LEZ_RPC:-http://127.0.0.1:3040}"
export MUSTER_LEZ_VERSION=v0.4.0-rc3          # the funder runs the v0.4 wallet
FUNDER=infra/lez/funder.sh
rpc() {  # method params-json → result JSON
  curl -s -m 10 -X POST "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" |
    python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("result")))'
}
b58() { python3 - "$1" <<'PY'
import sys
raw = bytes.fromhex(sys.argv[1]); n = int.from_bytes(raw, "big"); out = ""
a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
while n: n, r = divmod(n, 58); out = a[r] + out
print("1" * (len(raw) - len(raw.lstrip(b"\0"))) + out)
PY
}
[ "$(rpc getFeeState '[]')" != null ] || { echo "no LEZ v0.4 zone at $RPC: MUSTER_LEZ_VERSION=v0.4.0-rc3 infra/lez/localnet.sh"; exit 1; }
# a funded member account: enough for the top-up and the deposit; on the devnet, keep it small
MEMBER_FUND="${MSIG_MEMBER_FUND:-1000000000}"

PROGRAM="${MSIG_PROGRAM:-}"
if [ -z "$PROGRAM" ]; then
  out=$("$FUNDER" --zone "$RPC" deploy programs/lez-msig/lez04/artifacts/msig.bin) || { echo "deploy failed: $out"; exit 1; }
  PROGRAM=$(echo "$out" | grep -o '(hex [0-9a-f]\{64\}' | tail -1 | cut -c6-)
fi
[ ${#PROGRAM} = 64 ] || { echo "no program account id"; exit 1; }

D=$(mktemp -d)
TOPIC="/muster/1/lez-msig-private-$(date +%s)/proto"
CFG=$(ui_fleet_config)
PAY=1200
lg() { sed 's/\\"/"/g' "$1" 2>/dev/null; }
LEZ=(MUSTER_LEZ_RPC="$RPC" MUSTER_LEZ_CHAIN=lez:local MUSTER_LEZ_MSIG_PROGRAM="$PROGRAM")
[ "${MSIG_REAL_PROOFS:-0}" = 1 ] || LEZ+=(RISC0_DEV_MODE=1)
WAIT_S="${MSIG_WAIT_S:-900}"
echo "program: $PROGRAM · topic: $TOPIC · logs: $D"

read -r TO TOKEY < <("$FUNDER" --zone "$RPC" new-account) || { echo "no payee account"; exit 1; }
"$FUNDER" --zone "$RPC" fund "$TO" 1 "$TOKEY" >/dev/null || { echo "could not fund the payee"; exit 1; }
ui_launch "$D/A" "$D/A.log" HOME="$D/A-home" QT_FORCE_STDERR_LOGGING=1 "${LEZ[@]}" \
  MUSTER_AUTOADMIT=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=msigPA \
  MUSTER_AUTOMSIG_OPEN=2 MUSTER_AUTOMSIG_PRIVATE=1 MUSTER_AUTOMSIG_TOPUP=40000000 MUSTER_AUTOMSIG_FUND=5000 \
  MUSTER_AUTOMSIG_PAY="$TO:$PAY" MUSTER_AUTOMSIG_SETTLE=1
CFG_B=$(ui_peer_config "$D/A.log") || exit 1
ui_launch "$D/B" "$D/B.log" HOME="$D/B-home" QT_FORCE_STDERR_LOGGING=1 "${LEZ[@]}" \
  MUSTER_DELIVERY_CONFIG="$CFG_B" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=msigPB MUSTER_AUTOMSIG_APPROVE=1
payer_of() { lg "$D/$1.log" | grep -a 'MSIG payer' | head -1; }

funded=""; ok=0; T0=$SECONDS
echo "running the ceremony, top-up, create, deposit, propose, approve, settle (up to ${WAIT_S}s)..."
while [ $((SECONDS - T0)) -lt "$WAIT_S" ]; do
  sleep 2
  for who in A B; do   # fund each runner's own LEZ account once it names it, admitted by its key
    case " $funded " in *" $who "*) continue ;; esac
    line=$(payer_of "$who")
    acct=$(echo "$line" | grep -o '"account":"[0-9a-f]\{64\}"' | head -1 | cut -d'"' -f4)
    key=$(echo "$line" | grep -o '"key":"[0-9a-f]\{64\}"' | head -1 | cut -d'"' -f4)
    [ -n "$acct" ] && [ -n "$key" ] && "$FUNDER" --zone "$RPC" fund "$acct" "$MEMBER_FUND" "$key" >/dev/null &&
      funded="$funded $who" && echo "funded $who's account $acct after $((SECONDS - T0))s"
  done
  bal=$(rpc getAccountBalance "[\"$(b58 "$TO")\"]")
  if [ "$bal" = "$((1 + PAY))" ] && grep -aq 'MSIG intent .* final' "$D/A.log" && grep -aq 'MSIG intent .* final' "$D/B.log"; then
    ok=1; break
  fi
done
ui_cleanup
# a log line can pack several messages: take each one by its own marker
for who in A B; do echo "$who: $(lg "$D/$who.log" | grep -aoE 'MSIG intent [^\\]{0,100}' | tail -1)"; done
echo "A topup: $(lg "$D/A.log" | grep -aoE 'MSIG topup -> [^\\]{0,160}' | tail -1)"
echo "A fund: $(lg "$D/A.log" | grep -aoE 'MSIG fund -> [^\\]{0,160}' | tail -1)"
lg "$D/A.log" | grep -aoE 'MUSTER lez-msig job [^\\]{0,300}' | tail -3
if [ "$ok" = 1 ]; then
  echo "SUCCESS: a private 2-of-2 lez-msig on LEZ v0.4, made and settled from the room, paid exactly $PAY; both runners final after $((SECONDS - T0))s."
  [ "${KEEP_LOGS:-0}" = 1 ] || rm -rf "$D"
else
  echo "FAIL (the payee holds ${bal:-?}): logs kept in $D"
  lg "$D/A.log" | grep -aoE 'MSIG (open|topup|account|fund|proposed|intent)[^\\]{0,200}' | tail -8
  exit 1
fi
