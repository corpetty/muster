{
  description = "Muster module — Nim core behind the muster.lidl contract (P0 loading spike)";

  inputs = {
    # Local checkout with the codegen.nim path (B1). Switch to a pinned
    # github ref once the Nim path lands upstream.
    logos-module-builder.url = "path:/home/petty/Github/logos-co/logos-module-builder";
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
