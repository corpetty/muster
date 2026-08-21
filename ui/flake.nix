{
  description = "muster-ui — QML view + C++ backend calling muster_module through the logos API (P4 loading spike)";

  inputs = {
    # The muster core module — kept as an input ONLY so its published `.lidl`
    # output (packages.<sys>.lidl, a copy of the committed muster.lidl) is read
    # to generate the typed modules().muster_module client. Its own plugin is
    # built by its own flake (the Nim-cdylib builder) and is NOT rebuilt here.
    muster_module.url = "path:/home/petty/Github/corpetty/muster/module";
    # ADR-013: build the UI on a basecamp-COHERENT builder instead of following
    # muster_module's Nim-cdylib builder, so the generated client + QtRO view-glue
    # compile against basecamp's own cpp-sdk/qt-sdk/protocol and ABI-match its
    # ui-host (exo-c6a). Pinned to basecamp's current top-level builder rev.
    logos-module-builder.url = "github:logos-co/logos-module-builder/4717b9af35d88a20a960067ee55bc5417af5a1f0";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      # metadata.json#dependencies = ["muster_module"], resolved from the input
      # of the same name so the generated modules().muster_module client is typed.
      flakeInputs = inputs;
    };
}
