#!/usr/bin/env bash
# Regenerate generated/provider_gen.rs with the SAME logos-lidl-gen the module builder runs:
# logos-module-builder 0.3.3 locks logos-rust-sdk 040e94e8 (Basecamp 0.3.2's generation). In
# nix the builder writes its own copy; this one is for `cargo build` / `cargo test` here.
set -euo pipefail
cd "$(dirname "$0")/.."   # lez04: the v0.4 module package (exo-cc7)
REV=040e94e83873249dc5f27da8c2a01c3dcaaa630d
locked=$(nix flake metadata --json github:logos-co/logos-module-builder/0.3.3 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["locks"]["nodes"]["logos-rust-sdk"]["locked"]["rev"])')
[ "$locked" = "$REV" ] || { echo "builder 0.3.3 locks logos-rust-sdk $locked; Cargo.toml pins $REV" >&2; exit 1; }
gen=$(nix build --no-link --print-out-paths "github:logos-co/logos-rust-sdk/$REV#lidl-gen")
mkdir -p generated
"$gen/bin/logos-lidl-gen" lez_msig_v04_module.lidl --provider --protocol-version 0.9.0 -o generated/provider_gen.rs
echo "generated/provider_gen.rs from lez_msig_v04_module.lidl (logos-rust-sdk ${REV:0:8})"
