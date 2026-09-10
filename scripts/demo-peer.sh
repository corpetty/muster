#!/usr/bin/env bash
# Launch one seeded Muster demo peer from the public AppImage.
#
# The two-party Safe+FROST demo needs each participant's in-app account to BE a real
# anvil Safe owner (anvil accounts 0/1/2), so its auto-signed approval settles on
# chain (module/nim-lib/muster_module.nim: MUSTER_DEV_SECP_KEY seeds the keystore on
# first mint; the Safe's owners are hardcoded to anvil 0/1/2). This wrapper sets that
# env for you and launches the AppImage. See docs/two-party-demo-runbook.md.
#
# Usage:
#   scripts/demo-peer.sh alice                 # seed as anvil owner 0, real $HOME
#   scripts/demo-peer.sh bob   --isolate       # seed as owner 1, isolated $HOME
#   scripts/demo-peer.sh carol                 # seed as owner 2
#   scripts/demo-peer.sh alice --appimage /path/to/logos-basecamp.AppImage
#
#   --isolate      run under a per-role $HOME (…/.cache/muster-demo/<role>) so TWO
#                  peers on ONE machine get separate basecamp data dirs + identities.
#                  Omit on a two-machine demo (each machine already has its own $HOME).
#   --appimage P   AppImage path (default: <repo>/result-appimage/logos-basecamp.AppImage).
#   --fresh        wipe this role's isolated $HOME first (start from a clean identity).
#
# The FROST/threshold track needs NO seeding and NO anvil — any two peers who join the
# same room ARE the roster. Seeding only matters for the on-chain Safe settle. You can
# still run this wrapper for a FROST-only peer; the unused key just seeds an identity.
set -euo pipefail

ROLE="${1:-}"; shift || true
ISOLATE=0; FRESH=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APPIMAGE="$REPO/result-appimage/logos-basecamp.AppImage"

while [ $# -gt 0 ]; do
  case "$1" in
    --isolate) ISOLATE=1 ;;
    --fresh)   FRESH=1 ;;
    --appimage) APPIMAGE="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# anvil deterministic accounts 0/1/2 — the MiniSafe owner set (infra/anvil/devnet.sh).
case "$ROLE" in
  alice) KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 ;; # owner 0  0xf39Fd6…2266
  bob)   KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d ;; # owner 1  0x709797…79C8
  carol) KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a ;; # owner 2  0x3C44Cd…93BC
  *) echo "usage: $0 <alice|bob|carol> [--isolate] [--fresh] [--appimage PATH]" >&2; exit 2 ;;
esac

if [ ! -f "$APPIMAGE" ]; then
  echo "AppImage not found: $APPIMAGE" >&2
  echo "build it first:  cd $REPO && make appimage   (or pass --appimage PATH)" >&2
  exit 1
fi

export MUSTER_DEV_SECP_KEY="$KEY"
export MUSTER_KEY_PASSPHRASE="muster-demo"      # stable dev passphrase for the keyfile
export APPIMAGE_EXTRACT_AND_RUN=1

if [ "$ISOLATE" = "1" ]; then
  export HOME="${XDG_CACHE_HOME:-$HOME/.cache}/muster-demo/$ROLE"
  [ "$FRESH" = "1" ] && rm -rf "$HOME"
  mkdir -p "$HOME"
  echo "→ $ROLE : isolated HOME=$HOME"
fi

echo "→ $ROLE : seeded as anvil owner (MUSTER_DEV_SECP_KEY set), launching AppImage"
echo "  RPC defaults to http://127.0.0.1:8545 (local anvil). For a two-machine Safe"
echo "  settle, point this peer's RPC at the anvil host in Settings → Infrastructure."
exec "$APPIMAGE"
