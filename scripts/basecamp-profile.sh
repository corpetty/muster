#!/usr/bin/env bash
# Muster in a Basecamp release, the way a person installs it (exo-d4d.1, R0;
# docs/design/real-use-basecamp.md §4). One isolated Basecamp profile per name:
#
#   scripts/basecamp-profile.sh alice [--fresh] [--xvfb :97] [--no-launch]
#
# It installs into .run/basecamp/<name>/ (Basecamp's --user-dir):
#   1. the release AppImage (infra/basecamp/release-0.3.1.env), downloaded once and checked;
#   2. the default-catalog packages muster depends on (infra/basecamp/catalog-0.3.1.tsv),
#      each checked against the catalog's sha256: keystore_module and its signer and
#      custodian UIs, eth_rpc_module, fee_module, tx_sender_module, delivery_module,
#      lez_core, the RLN modules. A local install resolves no dependencies, so these go first;
#   3. muster_module and muster_ui from this tree, as .#lgx-portable (the release accepts
#      only the portable variant);
# then launches Basecamp on that profile. Nothing is seeded: no MUSTER_* variable is set.
#
#   --fresh      wipe the profile first (its keys, its chains, muster's identity)
#   --xvfb :N    run on a virtual display (Qt's software renderer), for a machine with no
#                screen; screenshots: import -display :N -window root shot.png
#   --no-launch  install only
#
# The AppImage's sha256 is the one first downloaded here (2026-10-03): the release
# publishes none. Logs: .run/basecamp/<name>.log, capped (scripts/lib/caplog.py, exo-9eed).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NAME=${1:-}; shift || true
[ -n "$NAME" ] || { echo "usage: $0 <name> [--fresh] [--xvfb :N] [--no-launch]" >&2; exit 2; }
FRESH=0; XDISPLAY=""; LAUNCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    --xvfb) XDISPLAY=${2:?--xvfb needs a display, e.g. :97}; shift ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
SUB=(--extra-substituters https://cache.nix.logos.co)
. infra/basecamp/release-0.3.1.env
BASE=$ROOT/.run/basecamp
PROFILE=$BASE/$NAME
mkdir -p "$BASE/catalog"

# 1. the release
APPIMAGE=$BASE/LogosBasecamp-$BASECAMP_TAG.AppImage
if [ ! -x "$BASE/squashfs-$BASECAMP_TAG/AppRun" ]; then
  [ -f "$APPIMAGE" ] || curl -sSL -o "$APPIMAGE" "$BASECAMP_URL"
  echo "$BASECAMP_SHA256  $APPIMAGE" | sha256sum -c --quiet
  chmod +x "$APPIMAGE"
  (cd "$BASE" && rm -rf squashfs-root && "$APPIMAGE" --appimage-extract >/dev/null && mv squashfs-root "squashfs-$BASECAMP_TAG")
fi
LGPM=$(nix build "$LGPM_FLAKE" "${SUB[@]}" --no-link --print-out-paths | tail -1)/bin/lgpm

# 2. the catalog packages
grep -v '^#' infra/basecamp/catalog-$BASECAMP_TAG.tsv | while IFS=$'\t' read -r pkg url sha; do
  f=$BASE/catalog/$pkg.lgx
  [ -f "$f" ] && echo "$sha  $f" | sha256sum -c --quiet 2>/dev/null && continue
  curl -sSL -o "$f" "$url"
  echo "$sha  $f" | sha256sum -c --quiet
done

# 3. muster, from this tree
MOD=$( (cd module && nix build .#lgx-portable "${SUB[@]}" --no-link --print-out-paths) | tail -1)
UI=$( (cd ui && nix build .#lgx-portable "${SUB[@]}" --no-link --print-out-paths) | tail -1)

# the profile
if pgrep -f -- "--user-dir $PROFILE\$" >/dev/null; then
  echo "Basecamp is already running on $PROFILE; stop it first" >&2; exit 1
fi
[ $FRESH = 1 ] && rm -rf "$PROFILE"
mkdir -p "$PROFILE"
inst() { "$LGPM" --modules-dir "$PROFILE/modules" --ui-plugins-dir "$PROFILE/plugins" --allow-unsigned install "$@" >/dev/null; }
inst --dir "$BASE/catalog"
inst --file "$MOD"/*.lgx
inst --file "$UI"/*.lgx
echo "profile $PROFILE: $("$LGPM" --modules-dir "$PROFILE/modules" --ui-plugins-dir "$PROFILE/plugins" list --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?') packages"

[ $LAUNCH = 1 ] || exit 0
LOG=$BASE/$NAME.log
if [ -n "$XDISPLAY" ]; then
  if ! [ -e "/tmp/.X11-unix/X${XDISPLAY#:}" ]; then
    XV=$(ls -d /nix/store/*-xvfb-21*/bin 2>/dev/null | head -1)/Xvfb
    [ -x "$XV" ] || XV=$(nix build nixpkgs#xvfb --no-link --print-out-paths | tail -1)/bin/Xvfb
    "$XV" "$XDISPLAY" -screen 0 1400x900x24 -nolisten tcp >/dev/null 2>&1 &
    sleep 2
  fi
  env -u WAYLAND_DISPLAY DISPLAY="$XDISPLAY" QT_QPA_PLATFORM=xcb QT_QUICK_BACKEND=software \
    "$BASE/squashfs-$BASECAMP_TAG/AppRun" --user-dir "$PROFILE" 2>&1 | python3 scripts/lib/caplog.py "$LOG" >/dev/null 2>&1 &
else
  "$BASE/squashfs-$BASECAMP_TAG/AppRun" --user-dir "$PROFILE" 2>&1 | python3 scripts/lib/caplog.py "$LOG" >/dev/null 2>&1 &
fi
echo "Basecamp $BASECAMP_TAG on $PROFILE (pid $!), log $LOG"
