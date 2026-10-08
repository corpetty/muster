#!/usr/bin/env bash
# The UI parity suite (exo-607 T0): every offscreen self-test, one at a time, against
# the UI build MUSTER_UI selects (cpp by default, nim for the seaqt port). The Nim
# build is done when this is green with MUSTER_UI=nim exactly as it is with cpp.
#   scripts/ui-parity.sh                  # the C++ build (.run/runner)
#   MUSTER_UI=nim scripts/ui-parity.sh    # the Nim build (.run/runner-nim)
#   scripts/ui-parity.sh card invite      # only the named tests
#   MUSTER_FLEET=local scripts/ui-parity.sh   # no fleet: the instances' own network (exo-eb6.7)
# Each test runs on the live Logos fleet (MUSTER_FLEET, logos.dev by default), or with
# MUSTER_FLEET=local on a network the instances make on this host, which checks the code
# while the fleet is down. split also starts a throwaway anvil, split-btc a
# fresh Bitcoin Core regtest (bitcoind via nix shell). The LEZ
# testnet split (~25 min, real proofs) is not in the suite: run it by hand.
set -uo pipefail
cd "$(dirname "$0")/.."
export MUSTER_UI="${MUSTER_UI:-cpp}"
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
  [split]="scripts/split-self-test.sh"
  [split-btc]="nix shell nixpkgs#bitcoind -c scripts/split-btc-self-test.sh"
)
ORDER=(card install infra-safe infra-threshold audit invite two-instance relaunch split split-btc)
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
echo "UI parity · MUSTER_UI=$MUSTER_UI · MUSTER_FLEET=$MUSTER_FLEET · $(git rev-parse --short HEAD) · $(date -u +%Y-%m-%dT%H:%MZ)"
fail=0
for name in "${ORDER[@]}"; do
  printf '  %-16s %-6s %4ss\n' "$name" "${RESULT[$name]}" "${SECS[$name]}"
  [ "${RESULT[$name]}" = green ] || fail=1
done
echo "logs: $LOGS"
exit $fail
