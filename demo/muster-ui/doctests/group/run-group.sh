#!/usr/bin/env bash
# Role: headless three-party group-chat test driver (CI); see run-group-show.sh for the doc-test display variant.
# Regenerate the three-instance group-chat screenshots for the docs.
#
# Launches three logos-chat-ui instances offscreen — each with its own data dir
# and QML inspector port — drives a real group conversation between them via the
# logos-qt-mcp inspector protocol (run-group.mjs): Alice creates the group,
# invites Bob and Carol, and once the roster converges sends a message that fans
# out to both. Writes the screenshots to OUT_DIR and exits non-zero if the flow
# does not complete, so this doubles as an end-to-end integration check. The three
# instances coexist because each picks a random QtRO socket name and its own
# delivery ports, and we give each a distinct data dir / inspector port.
#
# Usage:
#   doctests/group/run-group.sh [out-dir]
# Env:
#   FLAKE        flake ref to build the app from (default ".")
#   APP_BIN      run-logos-standalone-ui path; if unset, built from FLAKE
#   OUT_DIR      screenshot dir (default arg1, else docs/images/group)
#   WORK_DIR     per-instance data/log dir; if unset, a fresh mktemp is used
#   KEEP_WORK_DIR  if set, WORK_DIR is left in place on exit (e.g. to keep the
#                  app logs); processes are still torn down
#   KEEP_INSTANCES if set, a *successful* run leaves the three instances running
#                  (and their WORK_DIR in place) — the caller owns their
#                  teardown; a failed run still tears everything down
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
OUT_DIR="${OUT_DIR:-${1:-$repo_root/docs/images/group}}"
FLAKE="${FLAKE:-$repo_root}"
ALICE_PORT="${ALICE_PORT:-3768}"
BOB_PORT="${BOB_PORT:-3769}"
CAROL_PORT="${CAROL_PORT:-3770}"
WORK_DIR="${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/chat-group.XXXXXX")}"
mkdir -p "$OUT_DIR" "$WORK_DIR"

if [ -z "${APP_BIN:-}" ]; then
  echo "resolving the standalone app launcher from $FLAKE ..."
  system="$(nix eval --raw --impure --expr builtins.currentSystem)"
  APP_BIN="$(nix eval --raw "$FLAKE#apps.$system.default.program")"
  # Build the launcher's *derivation*, not its output path. `nix build
  # /nix/store/<out>` has no .drv to build from and can only substitute, so a
  # binary-cache miss fails with "no substituter that can build it". Recover the
  # drv from the SAME flake eval as APP_BIN (getContext over its program string)
  # so the build target matches the launch target and a miss builds from source.
  app_drv="$(nix eval --raw --apply \
    'p: builtins.head (builtins.attrNames (builtins.getContext p))' \
    "$FLAKE#apps.$system.default.program")"
  nix build --no-link "$app_drv^*"
fi
echo "app: $APP_BIN"

# The app fans out into one host process per module (logos_host_qt for
# capability_module / chat_module / delivery_module, plus ui-host), each in its
# own session — so killing the launched PID's process group misses them. Snapshot
# the logos process set before launch and, on exit, kill exactly the processes
# our run added (the set difference), which never touches pre-existing instances.
LOGOS_PAT='logos_host_qt|logos-standalone-app|ui-host'
PRE_PIDS="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
group_done=""
cleanup() {
  if [ -n "${KEEP_INSTANCES:-}" ] && [ -n "$group_done" ]; then
    return  # the caller owns the still-running instances and their WORK_DIR
  fi
  local now ours
  now="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
  ours="$(comm -13 <(printf '%s\n' "$PRE_PIDS") <(printf '%s\n' "$now") || true)"
  [ -n "$ours" ] && kill -9 $ours 2>/dev/null || true
  [ -n "${KEEP_WORK_DIR:-}" ] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

launch() {
  local name="$1" inspector="$2"
  mkdir -p "$WORK_DIR/$name"
  QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
    QML_INSPECTOR_PORT="$inspector" \
    setsid "$APP_BIN" -platform offscreen --user-dir "$WORK_DIR/$name" \
      > "$WORK_DIR/$name.log" 2>&1 &
  echo "launched $name (inspector $inspector)"
}

# Surface each instance's boot/runtime output — the apps launch headless, so
# their logs are the only window into a node that failed to boot or to reach the
# network (e.g. a delivery node still peering, or one that crashed under the load
# of three full stacks on one host).
dump_app_logs() {
  for f in "$WORK_DIR"/*.log; do
    [ -f "$f" ] || continue
    echo "::group::app log $(basename "$f")" >&2
    cat "$f" >&2
    echo "::endgroup::" >&2
  done
}

wait_for_port() {
  local port="$1"
  for _ in $(seq 1 120); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
    sleep 1
  done
  echo "inspector on port $port never came up" >&2
  dump_app_logs
  return 1
}

launch alice "$ALICE_PORT"
launch bob   "$BOB_PORT"
launch carol "$CAROL_PORT"
wait_for_port "$ALICE_PORT"
wait_for_port "$BOB_PORT"
wait_for_port "$CAROL_PORT"

# Dump the app logs on any driver failure (e.g. a node that never reaches
# Online) before the EXIT trap tears the work dir down — they show whether a node
# crashed or was still connecting.
if ! OUT_DIR="$OUT_DIR" ALICE_PORT="$ALICE_PORT" BOB_PORT="$BOB_PORT" CAROL_PORT="$CAROL_PORT" \
     node "$here/run-group.mjs"; then
  dump_app_logs
  exit 1
fi
group_done=1
