{
  description = "Muster module — Nim core behind the muster.lidl contract (P0 loading spike)";

  inputs = {
    # The Nim cdylib authoring path (B1). PR #202 landed codegen.nim upstream
    # (2026-08-31, master 65c3b58) but stdlib-only; this module additionally
    # needs codegen.nim.packages — the pinned nimble deps the whole ADR-014
    # Nimbus/Status reuse rides on (stint, nim-eth, nim-web3, nimcrypto,
    # nim-secp256k1 with submodules) — and the RUNPATH half of nim.link, without
    # which logos-core's LD_LIBRARY_PATH-less load cannot dlopen libsodium.
    # Both are upstream-pending in logos-co/logos-module-builder#226, so this
    # pins the PR's own rev on the fork. It is a real github ref, not a machine
    # path: a fresh clone builds from it. Repoint at logos-co master once #226
    # merges.
    logos-module-builder.url = "github:corpetty/logos-module-builder/720ac2feb72eca60e73c9aba5a9f9ad579de1cb7";
    # The real transport (P3): muster_module calls delivery_module over the lp_*
    # C ABI (src/transport/delivery.nim) — it boots delivery's embedded Waku node
    # and carries the sealed coordination frames. Same repo the demo consumes
    # (v0.2.0); mapped to the module name `delivery_module` below so
    # metadata.json#dependencies resolves it into the host module set.
    logos-delivery-module.url = "github:logos-co/logos-delivery-module/v0.2.0";
  };

  outputs = inputs@{ self, logos-module-builder, ... }:
    let
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in {
      packages = forAllSystems (system:
        (logos-module-builder.lib.mkLogosModule {
          src = ./.;
          configFile = ./metadata.json;
          flakeInputs = { delivery_module = inputs.logos-delivery-module; } // inputs;
        }).packages.${system});
    };
}
