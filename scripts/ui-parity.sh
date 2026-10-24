#!/usr/bin/env bash
# The UI parity suite (exo-607 T0): every offscreen self-test, one at a time, against
# the UI build MUSTER_UI selects (cpp by default, nim for the seaqt port). The Nim
# build is done when this is green with MUSTER_UI=nim exactly as it is with cpp.
#   scripts/ui-parity.sh                  # the C++ build (.run/runner)
#   MUSTER_UI=nim scripts/ui-parity.sh    # the Nim build (.run/runner-nim)
#   scripts/ui-parity.sh card invite      # only the named tests
#   MUSTER_FLEET=local scripts/ui-parity.sh   # no fleet: the instances' own network (exo-eb6.7)
#   MUSTER_UI=dev scripts/ui-parity.sh    # THIS tree's QML, live: a dev runner (a built
#                                         # runner's compiled code, scripts/lib/ui-dev.sh) on a
#                                         # private Xvfb, where the QML view is instantiated —
#                                         # offscreen it never is (exo-720)
# Each test runs on the live Logos fleet (MUSTER_FLEET, logos.dev by default), or with
# MUSTER_FLEET=local on a network the instances make on this host, which checks the code
# while the fleet is down. split also starts a throwaway anvil, split-btc a
# fresh Bitcoin Core regtest (bitcoind via nix shell); voice records from a WAV it writes and
# plays into a file, no audio device (docs/design/voice-notes.md S9). The LEZ
# testnet split (~25 min, real proofs) is not in the suite: run it by hand.
set -uo pipefail
# The suite's tables are associative arrays (bash 4). macOS's /bin/bash is 3.2, which fails
# on them and, before this check, exited 0 having run nothing.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "scripts/ui-parity.sh needs bash 4 or later, not $BASH_VERSION; on a Mac: nix shell nixpkgs#bash -c scripts/ui-parity.sh"
  exit 2
}
cd "$(dirname "$0")/.."
export MUSTER_UI="${MUSTER_UI:-cpp}"
if [ "$MUSTER_UI" = dev ]; then
  # the C++ backend with this tree's QML, drawn on an X display of our own
  . scripts/lib/ui-dev.sh
  ui_dev_runner "${MUSTER_BASE_RUNNER:-.run/runner}" .run/dev-parity || exit 1
  XV=$(ls -d /nix/store/*-xvfb-21*/bin 2>/dev/null | head -1)/Xvfb
  [ -x "$XV" ] || { echo "MUSTER_UI=dev needs Xvfb (nix build nixpkgs#xvfb-run)"; exit 1; }
  for disp in $(seq 140 199); do [ -e "/tmp/.X11-unix/X$disp" ] || break; done
  PARITY_X=$(mktemp -d)
  setsid bash -c 'echo $$ >"$1"; exec "$2" ":$3" -screen 0 1440x900x24 -nolisten tcp' _ "$PARITY_X/xvfb.pid" "$XV" "$disp" >/dev/null 2>&1 &
  trap 'pkill -9 -s "$(cat "$PARITY_X/xvfb.pid" 2>/dev/null)" 2>/dev/null' EXIT
  sleep 1
  unset WAYLAND_DISPLAY
  export DISPLAY=":$disp" MUSTER_QPA=xcb MUSTER_RUNNER="$PWD/.run/dev-parity/bin/muster-ui"
  export QT_FORCE_STDERR_LOGGING=1 XDG_CONFIG_HOME="$PARITY_X/config"
  export MUSTER_UI=cpp      # what the scripts themselves select: the C++ backend
  PARITY_LABEL="dev (this tree's QML, live on :$disp)"
fi
export MUSTER_FLEET="${MUSTER_FLEET:-logos.dev}"

declare -A SUITE=(
  [card]="scripts/card-self-test.sh"
  [install]="scripts/install-self-test.sh"
  [infra-safe]="scripts/infra-self-test.sh"
  [infra-threshold]="env POLICY=threshold scripts/infra-self-test.sh"
  [audit]="scripts/audit-download-self-test.sh"
  [invite]="scripts/invite-proof.sh"
  [two-instance]="scripts/two-instance-proof.sh"
  [relaunch]="scripts/relaunch-self-test.sh"
  [leave]="scripts/leave-self-test.sh"
  [room-copy]="scripts/room-copy-self-test.sh"
  [split]="scripts/split-self-test.sh"
  [split-btc]="nix shell nixpkgs#bitcoind -c scripts/split-btc-self-test.sh"
  [voice]="scripts/voice-self-test.sh"
)
ORDER=(card install infra-safe infra-threshold audit invite two-instance relaunch leave room-copy split split-btc voice)
[ $# -gt 0 ] && ORDER=("$@")

LOGS=$(mktemp -d)
declare -A RESULT SECS
for name in "${ORDER[@]}"; do
  cmd="${SUITE[$name]:-}"
  [ -n "$cmd" ] || { echo "unknown test '$name' (known: ${!SUITE[*]})"; exit 2; }
  echo "── $name ($MUSTER_UI) ──"
  start=$(date +%s)
  if $cmd >"$LOGS/$name.log" 2>&1; then RESULT[$name]=green; else RESULT[$name]=red; fi
  SECS[$name]=$(( $(date +%s) - start ))
  tail -3 "$LOGS/$name.log" | sed 's/^/  /'
done

echo
echo "UI parity · MUSTER_UI=${PARITY_LABEL:-$MUSTER_UI} · MUSTER_FLEET=$MUSTER_FLEET · $(git rev-parse --short HEAD) · $(date -u +%Y-%m-%dT%H:%MZ)"
fail=0
for name in "${ORDER[@]}"; do
  printf '  %-16s %-6s %4ss\n' "$name" "${RESULT[$name]}" "${SECS[$name]}"
  [ "${RESULT[$name]}" = green ] || fail=1
done
echo "logs: $LOGS"
exit $fail
