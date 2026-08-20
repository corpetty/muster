#!/usr/bin/env bash
# P4 acceptance harness for muster-ui: launch the module in the builder's
# ABI-matched standalone host and assert `muster_module.health() -> ok` surfaces
# in the view (health.mjs, over the QML inspector protocol).
#
# WHY the standalone host and not basecamp: shipping basecamp's ui-host is
# ABI-skewed from the nim-cdylib module-builder (logos-view-module-runtime +
# logos-cpp-sdk), so the muster-ui view crashes on instantiation there — see
# docs/labbook/nim-cdylib-modules-cannot-load-in-basecamp-sdk-skew.md. The
# standalone host (logos-standalone-app) bundles its OWN ui-host +
# capability_module built from the SAME builder as the plugin, so both ABI
# boundaries are self-consistent and the health() seam completes. This runs
# HEADLESS (offscreen + software render): the assertion reads the QML object tree,
# not pixels, so no display is required. When the upstream skew is fixed, re-point
# this at basecamp's logos-qt-mcp flow (the assertion in health.mjs is unchanged).
#
# Usage:   ui/tests/run-health.sh
# Env:
#   APP_BIN     run-logos-standalone-ui launcher; if unset, uses ./result-uidev,
#               else builds it from the ui flake.
#   INSPECTOR_PORT   QML inspector port (default 3771)
#   MUSTER_UI_PLATFORM   Qt platform (default "offscreen"; set "xcb" to watch it
#               on a real display — needs DISPLAY/WAYLAND_DISPLAY)
#   KEEP_WORK_DIR    keep the per-run --user-dir + app log on exit
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ui_root="$(cd "$here/.." && pwd)"
PORT="${INSPECTOR_PORT:-3771}"
PLATFORM="${MUSTER_UI_PLATFORM:-offscreen}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muster-health.XXXXXX")"
LOG="$WORK_DIR/app.log"

# Resolve the standalone launcher: prefer a prebuilt ./result-uidev, else build
# the flake's default app (its derivation, so a cache miss builds from source).
if [ -z "${APP_BIN:-}" ]; then
  if [ -x "$ui_root/result-uidev/bin/run-logos-standalone-ui" ]; then
    APP_BIN="$ui_root/result-uidev/bin/run-logos-standalone-ui"
  else
    echo "no ./result-uidev — building the standalone launcher from $ui_root ..."
    system="$(nix eval --raw --impure --expr builtins.currentSystem)"
    APP_BIN="$(nix eval --raw "$ui_root#apps.$system.default.program")"
    app_drv="$(nix eval --raw --apply \
      'p: builtins.head (builtins.attrNames (builtins.getContext p))' \
      "$ui_root#apps.$system.default.program")"
    nix build --no-link "$app_drv^*"
  fi
fi
echo "app:      $APP_BIN"
echo "platform: $PLATFORM   inspector port: $PORT"

# The launcher fans out into ui-host + one logos_host per module, each in its own
# session, so killing the launched PID's group misses them. Snapshot the logos
# process set before launch and, on exit, kill exactly the set our run added —
# never touching a pre-existing instance.
LOGOS_PAT='logos-standalone-app|logos_host|ui-host'
PRE_PIDS="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
cleanup() {
  local now ours
  now="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
  ours="$(comm -13 <(printf '%s\n' "$PRE_PIDS") <(printf '%s\n' "$now") 2>/dev/null || true)"
  [ -n "$ours" ] && kill -9 $ours 2>/dev/null || true
  [ -n "${KEEP_WORK_DIR:-}" ] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

QT_QPA_PLATFORM="$PLATFORM" QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
  QML_INSPECTOR_PORT="$PORT" \
  setsid "$APP_BIN" --user-dir "$WORK_DIR/ud" > "$LOG" 2>&1 &

wait_for_port() {
  for _ in $(seq 1 120); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    sleep 1
  done
  echo "inspector on port $PORT never came up" >&2
  return 1
}

if ! wait_for_port; then
  echo "::group::app log"; cat "$LOG" >&2; echo "::endgroup::"
  exit 1
fi

if INSPECTOR_PORT="$PORT" node "$here/health.mjs"; then
  echo "run-health: PASS"
else
  rc=$?
  echo "run-health: FAIL (health.mjs exit $rc) — app log follows" >&2
  echo "::group::app log"; cat "$LOG" >&2; echo "::endgroup::"
  exit $rc
fi
