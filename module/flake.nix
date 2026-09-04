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
    # The builder floats ALL its SDK inputs (logos-cpp-sdk.url et al. carry no rev),
    # so a plain pin drifts them to latest — which is how muster_module came to build
    # against logos-cpp-sdk@58c65737, a NEWER module-load contract than the shipping
    # logos-basecamp host provides. The module then imports a host symbol the host
    # doesn't export (logos_module_set_unload_done_callback) and crashes on load
    # (exo-222; docs/labbook/basecamp-sdk-skew-unload-callback.md). Pin the builder's
    # SDK set to basecamp's coherent generation (its own logos-co/4717b9af builder
    # set, captured 2026-09-03) so muster_module builds the SAME contract the host
    # loads. Re-capture these if basecamp's host SDK moves.
    logos-module-builder = {
      # basecamp's coherent builder (logos-co/4717b9af) + ONLY the three codegen
      # commits muster needs (65c3b58 #202, 165839f nim.packages, 720ac2f RUNPATH),
      # NONE of the fork's 78 SDK-bump commits that drift the load contract newer.
      # Branch: corpetty/logos-module-builder@codegen-on-basecamp. A fresh clone
      # builds from this github ref. Rebase onto basecamp's builder if the host SDK
      # generation moves (see docs/labbook/basecamp-sdk-skew-unload-callback.md).
      url = "github:corpetty/logos-module-builder/c10a94cd61f46777c799cef96d68b18bc898a479";
      inputs.logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk/c3fa1b5ad34f2afc113c9d6ca63bc29879d4868e";
      inputs.logos-qt-sdk.url = "github:logos-co/logos-qt-sdk/2ec59459a3a6ad541eab1b3b10861ae76575e488";
      inputs.logos-module.url = "github:logos-co/logos-module/2ec64c4a65f8966b5137cdba3a19a6498ce17b6d";
      inputs.logos-protocol.url = "github:logos-co/logos-protocol/6401e30ae1cfabac77285ee8e7a82c2cef3858f1";
      inputs.logos-plugin-qt.url = "github:logos-co/logos-plugin-qt/f33f264abb6d628cc78cf926f9f33c7cc8252151";
      inputs.logos-design-system.url = "github:logos-co/logos-design-system/94092b07d66df91ffdabb14495a1c90d6116b1b2";
      inputs.logos-rust-sdk.url = "github:logos-co/logos-rust-sdk/a55fdac1a202ff2a4cf9d562a263ab41db17d99f";
      inputs.logos-standalone-app.url = "github:logos-co/logos-standalone-app/c25aa61e3ad69358bbd9c8192c319ffcbf774189";
      inputs.logos-test-framework.url = "github:logos-co/logos-test-framework/eb1600cc6f61b66f6d75edd4773a58f0d1fa1ca4";
      inputs.logos-nix.url = "github:logos-co/logos-nix/e637a1f5e871244d1c2df1e3c52a067f2eb406f2";
      inputs.nix-bundle-lgx.url = "github:logos-co/nix-bundle-lgx/b49074a8e1157832002b11d3d254c1aaa4b96680";
      inputs.nix-bundle-logos-module-install.url = "github:logos-co/nix-bundle-logos-module-install/55de9a6fce755387224ececd0493f46b028ee0a3";
      inputs.rust-overlay.url = "github:oxalica/rust-overlay/14f58845249f3552a89b07772626b8d3c632fa86";
    };
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
