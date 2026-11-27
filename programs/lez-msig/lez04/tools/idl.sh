#!/usr/bin/env bash
# lez-msig's IDL (RFP-005 U.4, exo-7610): `spel generate-idl` over msig_core, with the message
# enum, the state type and the namespace named in ../spel.toml (no annotations in msig_core).
#
#   tools/idl.sh            regenerate idl/lez_msig.json
#   tools/idl.sh --check    fail if the committed IDL is not what SPEL generates, then decode
#                           Muster's State vector (module/tests/vectors/lez-msig) with it
#
# SPEL is pinned: logos-co/spel, branch refactor/lez-v0.4.x (the 0.4 line, LEZ v0.4.0-rc3).
# $SPEL names a binary to use; otherwise the pinned rev is installed once into
# ~/.cache/muster/spel-<rev>. Its wallet links Keycard support, so the build needs libpcsclite:
# with only the host's runtime library, a .pc over it is generated (as infra/lez/localnet.sh does).
set -euo pipefail
cd "$(dirname "$0")/.."   # lez04, where spel.toml lives
REV=0d42ddb914ddaf2766e0b94661d97d3a2886792b
IDL=idl/lez_msig.json

spel_bin() {
  if [ -n "${SPEL:-}" ]; then echo "$SPEL"; return; fi
  local root="$HOME/.cache/muster/spel-${REV:0:12}"
  if [ ! -x "$root/bin/spel" ]; then
    local syspcsc=/usr/lib/x86_64-linux-gnu/libpcsclite.so.1
    if ! pkg-config --exists libpcsclite 2>/dev/null && [ -e "$syspcsc" ]; then
      local pc="$root/.pcsc"; mkdir -p "$pc"
      ln -sf "$syspcsc" "$pc/libpcsclite.so"
      printf 'Name: libpcsclite\nDescription: host PC/SC\nVersion: 2\nLibs: -L%s -lpcsclite\nCflags:\n' "$pc" > "$pc/libpcsclite.pc"
      export PKG_CONFIG_PATH="$pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
    echo "installing spel ${REV:0:8} into $root (once; a few minutes)…" >&2
    cargo install --locked --git https://github.com/logos-co/spel --rev "$REV" spel --root "$root" >&2
  fi
  echo "$root/bin/spel"
}
spel=$(spel_bin)

if [ "${1:-}" = --check ]; then
  fresh=$(mktemp); trap 'rm -f "$fresh"' EXIT
  "$spel" generate-idl > "$fresh"
  if ! diff -u "$IDL" "$fresh"; then
    echo "$IDL is not what spel generates from ../core: run tools/idl.sh and commit it" >&2
    exit 1
  fi
  # the IDL decodes a real State: Muster's vector, written by msig_core's own borsh
  state=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["vectors"]["state"])' \
    ../../../module/tests/vectors/lez-msig/vectors.json)
  "$spel" inspect any --idl "$IDL" --data "$state" > /dev/null \
    || { echo "$IDL does not decode the state vector" >&2; exit 1; }
  echo "$IDL is current (spel ${REV:0:8}) and decodes the state vector"
else
  mkdir -p "$(dirname "$IDL")"
  "$spel" generate-idl > "$IDL"
  echo "$IDL from ../core (spel ${REV:0:8})"
fi
