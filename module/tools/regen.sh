#!/usr/bin/env bash
# Regenerate nim-lib/muster_gen.nim from src/api/muster.lidl in one command.
#
# The module surface is generated from the LIDL contract (ADR-008); until the
# builder runs this as part of its codegen step, run it by hand after editing
# muster.lidl. This wraps the multi-step recipe (build the LIDL C lib, build the
# generator against it, run it) so it is one command.
set -euo pipefail
cd "$(dirname "$0")/.."

lidl=/tmp/muster-lidl
gen=/tmp/muster-lidl-gen

echo "→ building the LIDL C library"
nix build github:logos-co/logos-lidl#logos-lidl --out-link "$lidl"

echo "→ building the generator (tools/lidl_gen.nim)"
nim c -d:LIDL_INC:"$lidl/include/lidl" \
      -d:LIDL_C_A:"$lidl/lib/liblogos_lidl_c.a" \
      -d:LIDL_A:"$lidl/lib/liblogos_lidl.a" \
      --out:"$gen" --hints:off tools/lidl_gen.nim

echo "→ generating nim-lib/muster_gen.nim"
"$gen" src/api/muster.lidl nim-lib/muster_gen.nim
