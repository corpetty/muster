#!/usr/bin/env bash
# Regenerate nim-lib/muster_gen.nim from src/api/muster.lidl in one command.
#
# The generator lives in the shared Nim SDK — github.com/corpetty/logos-nim-sdk —
# which muster consumes (see metadata.json codegen.nim.packages). This fetches the
# SAME pinned rev the build uses (single source of truth: metadata.json), builds
# its lidl-gen against the LIDL C library, and runs it in provider mode.
set -euo pipefail
cd "$(dirname "$0")/.."

lidl=/tmp/muster-lidl
sdk=/tmp/logos-nim-sdk
gen=/tmp/muster-lidl-gen

REV=$(python3 -c 'import json; ps=json.load(open("metadata.json"))["codegen"]["nim"]["packages"]; print(next(p["rev"] for p in ps if p["repo"]=="logos-nim-sdk"))')

echo "→ building the LIDL C library"
nix build github:logos-co/logos-lidl#logos-lidl --out-link "$lidl"

echo "→ fetching the SDK generator (logos-nim-sdk @ ${REV:0:12})"
if [ -d "$sdk/.git" ]; then git -C "$sdk" fetch -q origin; else git clone -q https://github.com/corpetty/logos-nim-sdk "$sdk"; fi
git -C "$sdk" checkout -q "$REV"

echo "→ building the SDK generator"
nim c -d:LIDL_INC:"$lidl/include/lidl" \
      -d:LIDL_C_A:"$lidl/lib/liblogos_lidl_c.a" \
      -d:LIDL_A:"$lidl/lib/liblogos_lidl.a" \
      --out:"$gen" --hints:off "$sdk/lidl-gen/lidl_gen.nim"

echo "→ generating nim-lib/muster_gen.nim (provider surface)"
"$gen" provider src/api/muster.lidl nim-lib/muster_gen.nim
