{
  description = "muster-ui — QML view + C++ backend calling muster_module through the logos API (P4 loading spike)";

  inputs = {
    # The muster core module; its own flake pins the Nim-codegen builder. The UI
    # follows THAT same builder so the QML build and the module build share one
    # logos-protocol/qt-sdk chain (mirrors demo/muster-ui following chat_module).
    muster_module.url = "path:/home/petty/Github/corpetty/muster/module";
    logos-module-builder.follows = "muster_module/logos-module-builder";
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
