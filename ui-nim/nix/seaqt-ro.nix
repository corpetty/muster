# nim-seaqt qt-6.8 plus QtRemoteObjects bindings (exo-607 T3), generated at BUILD time.
#
# nim-seaqt ships no QtRemoteObjects. seaqt-gen, its generator (Go, a miqt fork that
# parses Qt headers with clang), can emit it. This derivation runs the pinned generator
# with ./seaqt-gen-patches applied and adds its RemoteObjects output to nim-seaqt. The
# generated wrappers are C++ (gen_*.cpp/.h, compiled by seaqt's {.compile.} pragmas), so
# they are produced here and never committed. The repo carries only the generator
# patches, which is how "no C++ in the repo" holds while muster uses QtRO from Nim.
#
#   seaqt-gen  56485e6, the rev that produced nim-seaqt qt-6.8@7d40abd7 (a QtCore
#              regenerated with it is byte-identical in structure; the only diffs are
#              6.8.3 → 6.9.2 API changes)
#   patches    0001 add RemoteObjects to the module list (upstream-worthy)
#              0002 SEAQT_GEN_MODULES, to parse only RemoteObjects' closure (local)
#              0003 a parameter named `self` no longer collides (upstream-worthy, required)
#              0004 QSet<> return values emit valid Nim (upstream-worthy, required)
#   clang      14.0.6, the generator's own Docker version; clang >= 16 prints nested types
#              unqualified and the generator panics
#   Qt         the caller's qt6 (the runner's 6.9.2) through qt6.env, one merged include
#              tree so the generator finds <QT_INSTALL_HEADERS>/QtRemoteObjects
#
# Only Core, Network and RemoteObjects are parsed: Qt6RemoteObjects.pc requires exactly
# Qt6Core + Qt6Network, so that is the full closure and the output equals a full run's.
# The bindings carry GenVersion 6.9.2 (the rest of nim-seaqt says 6.8.3): Qt >= 6.9.
{ pkgs, nim-seaqt, seaqt-gen, clang14 }:

let
  qtEnv = pkgs.qt6.env "seaqt-gen-qt-${pkgs.qt6.qtbase.version}" [ pkgs.qt6.qtremoteobjects ];

  overlay = pkgs.stdenv.mkDerivation {
    pname = "nim-seaqt-remoteobjects";
    version = pkgs.qt6.qtbase.version;
    src = seaqt-gen;
    patches = [
      ./seaqt-gen-patches/0001-Qt-6-generate-QtRemoteObjects.patch
      ./seaqt-gen-patches/0002-genbindings-SEAQT_GEN_MODULES-filter-local.patch
      ./seaqt-gen-patches/0003-genbindings-a-parameter-named-self-no-longer-collide.patch
      ./seaqt-gen-patches/0004-nim-QSet-return-values-compile-CABI-type-is-seaqt_ar.patch
    ];
    nativeBuildInputs = [ pkgs.go clang14 pkgs.pkg-config qtEnv ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOPATH=$TMPDIR/go GOPROXY=off GOFLAGS=-mod=mod
      export QMAKE=${qtEnv}/bin/qmake PKG_CONFIG_PATH=${qtEnv}/lib/pkgconfig
      [ "$(clang --version | head -1 | awk '{print $3}')" = 14.0.6 ] || { echo "seaqt-ro: need clang 14.0.6" >&2; exit 1; }
      go build -o cmd/genbindings/genbindings ./cmd/genbindings
      (cd cmd/genbindings && \
        SEAQT_GEN_MODULES=Core,Network,RemoteObjects ./genbindings -clang clang -outdir $TMPDIR/out) \
        > $TMPDIR/genbindings.log 2>&1 || { tail -30 $TMPDIR/genbindings.log; exit 1; }
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      gen=$(echo $TMPDIR/out/nim-seaqt-*/seaqt)
      [ -d "$gen/QtRemoteObjects" ] || { echo "seaqt-ro: no QtRemoteObjects output" >&2; exit 1; }
      mkdir -p $out/seaqt/QtRemoteObjects
      cp $gen/QtRemoteObjects/* $out/seaqt/QtRemoteObjects/
      # The top-level forwarders (seaqt/qremoteobjectnode.nim, …) that import the module.
      for f in $gen/*.nim; do
        grep -q '^import ./QtRemoteObjects/' "$f" && cp "$f" $out/seaqt/
      done
      # What the generator could not bind in RemoteObjects, for the record.
      awk '/include\/QtRemoteObjects\//{ro=1} ro && /^Blocking method/' $TMPDIR/genbindings.log \
        > $out/ro-blocked.txt
      runHook postInstall
    '';
  };
in
# One source tree for `--path:`, a real copy: seaqt's {.compile.} pragmas and the
# generated headers' `#include "../libseaqt-runtime.h"` resolve relative to each file.
# The overlay only adds; the build fails if it would replace a nim-seaqt file.
pkgs.runCommand "nim-seaqt-with-remoteobjects" { passthru = { inherit overlay; }; } ''
  cp -r --no-preserve=mode ${nim-seaqt} $out
  cd ${overlay}
  for f in $(find seaqt -type f | sort); do
    if [ -e "$out/$f" ]; then
      echo "seaqt-ro: $f would replace a nim-seaqt file" >&2
      exit 1
    fi
    install -Dm644 "$f" "$out/$f"
  done
''
