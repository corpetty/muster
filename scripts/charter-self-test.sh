#!/usr/bin/env bash
# A room's charter, end to end through the real UI binary (exo-267.1) — no GUI, no clicks.
# Two offscreen runners in one room:
#   A founds the room, admits B, and once B is in proposes founding a charter from the
#     circle template (MUSTER_AUTOCHARTER — the Charter tab's "Propose founding it"); the
#     template's members default to the room's, so the founding names both;
#   both approve the founding on its card (MUSTER_AUTOCHARTER_APPROVE), and both see it in
#     force — a founding takes force only once every member it names agrees;
#   B then proposes an amendment, the charter renamed (MUSTER_AUTOCHARTER_AMEND — "Propose
#     this change"); B approves foundings only (MUSTER_AUTOCHARTER_APPROVE=founding), so
#     the amendment takes force by A's approval alone, under the charter in force's rule
#     (amend k = 1); both see the new name in force.
# Passes when both instances log the renamed charter in force, its history two long, and
# B never approved the amendment. The backend logs to stderr (QT_FORCE_STDERR_LOGGING), since
# the check reads its CHARTER lines; without it the C++ one logs to the journal.
#
# What this proves, and what it does not: the backend slots the Charter tab and the card
# call (proposeCharter / loadCharter / contributeInRoom), the module and the transport, in
# the real runner. Offscreen, the QML view is never instantiated
# (docs/labbook/qml-errors-are-invisible-to-nix-build.md): the tab and the card are
# checked in the gallery (room-details-charter*, card-charter-founding).
#
#   make build && scripts/charter-self-test.sh      # MUSTER_FLEET=local for no fleet; KEEP_LOGS=1
#
# Cleanup kills only this script's own processes (each runner's session), never another
# muster you may have running.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner

NAME="Tuesday circle"
RENAMED="Wednesday circle"
# CHARTER_FOUND adds to the founding spec, e.g. ,"share":"100","asset":"LEZ","cadence":604800
FOUND="{\"template\":\"circle\",\"name\":\"$NAME\",\"amendK\":1${CHARTER_FOUND:-}}"
AMEND="{\"template\":\"circle\",\"name\":\"$RENAMED\",\"amendK\":1}"
CFG=$(ui_fleet_config)
TOPIC="/muster/1/charter-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC · logs: $D"

launch() {  # name, extra env… — each runner in its own session, so cleanup can find it
  local name="$1"; shift
  env "$@" MUSTER_LP_DEBUG=1 QT_FORCE_STDERR_LOGGING=1 MUSTER_DELIVERY_CONFIG="$CFG" \
      MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID="charter$name" QT_QPA_PLATFORM="${MUSTER_QPA:-offscreen}" \
      setsid "$RUNNER" --user-dir "$D/$name" >"$D/$name.log" 2>&1 &
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

launch A MUSTER_AUTOADMIT=1 MUSTER_AUTOCHARTER="$FOUND" MUSTER_AUTOCHARTER_APPROVE=1
CFG=$(ui_peer_config "$D/A.log") || exit 1
launch B MUSTER_AUTOCHARTER_AMEND="$AMEND" MUSTER_AUTOCHARTER_APPROVE=founding

# the backend's lines, one per line: the C++ runner relays ui-host's log batched and
# quoted ("…\n…", \"), the Nim one writes it as is
lg() { sed 's/\\n/\n/g; s/\\"/"/g' "$D/$1.log" 2>/dev/null | grep -aE '\[muster_ui\] (CHARTER|SELFTEST)'; }
inforce() { lg "$3" | grep -aF "CHARTER found=true name=$1 history=$2" >/dev/null; }
echo "watching for the founding, then the amendment, in force on both instances (up to 240s)..."
ok=0; founded=""
for i in $(seq 1 240); do
  sleep 1
  [ -z "$founded" ] && inforce "$NAME" 1 A && inforce "$NAME" 1 B && { founded=$i; echo "founded on both after ~${i}s"; }
  inforce "$RENAMED" 2 A && inforce "$RENAMED" 2 B && { ok=1; break; }
done

saw() { lg "$2" | grep -aE "$1" >/dev/null && echo yes || echo no; }
echo "A sees B: $(saw 'SELFTEST.*self[^a-z]*:false' A) · A proposed the founding: $(saw 'CHARTER found -> .*"founding":true' A)" \
     "· B proposed the amendment: $(saw 'CHARTER amend -> .*"founding":false' B)" \
     "· approvals: A $(lg A | grep -ac 'CHARTER approved'), B $(lg B | grep -ac 'CHARTER approved')"
for n in A B; do lg $n | grep -aoE 'CHARTER (found ->|amend ->|approved) .*' | cut -c1-160 | sed "s/^/  $n │ /"; done
for n in A B; do lg $n | grep -aoE 'CHARTER found=.*' | uniq | sed "s/^/  $n │ /"; done

# B approves foundings only: had it approved its own amendment, A's approval proved nothing
AID=$(lg B | grep -aoE 'CHARTER amend -> \{"intentId":"0x[0-9a-f]+' | head -1 | grep -oE '0x[0-9a-f]+')
echo "the amendment: ${AID:-none}"
{ [ -n "$AID" ] && ! lg B | grep -aF "CHARTER approved $AID" >/dev/null; } || { echo "B approved its own amendment, or proposed none"; ok=0; }
if [ "$ok" = 1 ]; then
  echo "SUCCESS after ~${i}s: \"$NAME\" founded by both, amended to \"$RENAMED\" by A's approval, in force on both."
  cleanup; trap - EXIT
  [ -n "${KEEP_LOGS:-}" ] && echo "logs kept in $D" || rm -rf "$D"
else
  echo "FAIL: founded=${founded:-no}, amendment in force on both=$ok — logs kept in $D"
  exit 1
fi
