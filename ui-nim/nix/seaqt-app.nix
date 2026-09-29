# Build one seaqt app: `nim c` with nim-seaqt + nimside on the path, against qt6 from
# the caller's nixpkgs (the flake passes the runner's). seaqt's {.compile.} pragmas
# build its generated C++ wrappers during `nim c`, reading cflags from pkg-config —
# that C++ exists only in the build, never in the repo (exo-607's "no C++" reading).
{ lib, stdenv, nim, pkg-config, qt6, nim-seaqt, nimside }:

{ pname
, version ? "0.1.0"
, src
, main                # the .nim entry point, relative to src
, qml ? [ ]           # QML files installed to $out/share/<pname>/
, nimFlags ? [ ]
, extraAttrs ? { }    # passed through to mkDerivation, e.g. qtWrapperArgs
}:

stdenv.mkDerivation ({
  inherit pname version src;

  nativeBuildInputs = [ nim pkg-config qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase qt6.qtdeclarative ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    # seaqt's wrappers are C++ but nim links with the C driver, so libstdc++ is named.
    nim c -d:release --mm:orc --threads:on --hints:off \
      --nimcache:$TMPDIR/nimcache --passL:-lstdc++ \
      --path:${nim-seaqt} --path:${nimside}/src \
      ${lib.escapeShellArgs nimFlags} \
      -o:${pname} ${main}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ${pname} $out/bin/${pname}
    ${lib.concatMapStringsSep "\n" (f: "install -Dm644 ${f} $out/share/${pname}/${f}") qml}
    runHook postInstall
  '';

  meta.mainProgram = pname;
} // extraAttrs)
