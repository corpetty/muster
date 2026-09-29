#!/usr/bin/env bash
# T4a of exo-607, option B's core half: the Nim host (ui-nim#muster-app) starts
# logos-core in its own process, loads muster_module and its dependencies (each in a
# logos_host), registers the view's token with capability_module, and calls
# muster_module.health() over lp_*. The real Main.qml is loaded too. It passes when
# health reaches the view's PROP as "ok". The view half alone runs in the nix
# sandbox (ui-nim#checks.<system>.muster-app-view). This half needs live module
# processes, so it runs here, against the modules the C++ runner was built with.
# Cleanup kills only this probe's session, never another session's runners.
set -uo pipefail
cd "$(dirname "$0")/.."
RUNNER=".run/runner/bin/muster-ui"
[ -x "$RUNNER" ] || { echo "build the runner first: make build (its modules dir is what the Nim host loads)"; exit 1; }
LAUNCH=$(grep -oE '/nix/store/[^ "]+/bin/run-logos-standalone-ui' "$RUNNER" | head -1)
MODULES=$(grep -oE -- '--modules-dir "[^"]+"' "$LAUNCH" | cut -d'"' -f2)
[ -d "$MODULES" ] || { echo "could not find the runner's modules dir (from $LAUNCH)"; exit 1; }
APP=$(cd ui-nim && nix build .#muster-app --no-link --print-out-paths --accept-flake-config 2>/dev/null) \
  || { echo "could not build ui-nim#muster-app"; exit 1; }
D=$(mktemp -d)
echo "modules: $MODULES"
echo "app:     $APP"
INSTANCE="nimapp$$"
# The app writes its own pid from inside its new session: `setsid` forks when its caller
# leads a process group, and then $! names a process that has already gone; -w keeps
# setsid itself alive until the app exits, so `wait` gets the app's status.
LOGOS_INSTANCE_ID="$INSTANCE" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  setsid -w bash -c 'echo $$ >"$1/pid"; shift; exec "$@"' _ "$D" \
    "$APP/bin/muster-app" --self-test-core --modules "$MODULES" --user-dir "$D/user" >"$D/app.log" 2>&1 &
wait $!; rc=$?
# The app stops its module hosts itself (logos_core_cleanup). If it died before it could,
# they are in sessions of their own (liblogos starts them with setsid), so stop them by
# the instance id they inherited, and nothing else.
PID=$(cat "$D/pid" 2>/dev/null)
[ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
for p in $(pgrep -f 'logos_host' 2>/dev/null); do
  tr '\0' '\n' </proc/"$p"/environ 2>/dev/null | grep -qx "LOGOS_INSTANCE_ID=$INSTANCE" && kill -9 "$p" 2>/dev/null
done
grep -aE '^(PASS|FAIL|SUCCESS|FAILED)|QML:' "$D/app.log"
if [ "$rc" = 0 ]; then rm -rf "$D"; else echo "logs kept in $D"; fi
exit "$rc"
