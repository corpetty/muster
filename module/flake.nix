{
  description = "Muster module — Nim core behind the muster.lidl contract (P0 loading spike)";

  inputs = {
    # Local checkout with the codegen.nim path (B1). Switch to a pinned
    # github ref once the Nim path lands upstream.
    logos-module-builder.url = "path:/home/petty/Github/logos-co/logos-module-builder";
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
          flakeInputs = inputs;
        }).packages.${system});
    };
}
