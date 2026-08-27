#!/usr/bin/env bash
# Build muster_headless_host against a coherent logos-core (machine-pinned store paths —
# the nixify TODO in README.md replaces these with muster's own builder pin). The paths
# below are the coherent set found on the dev box: adjust if the store GCs them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

LL=/nix/store/mf14bh5z4dfip1prnqady2klg7qgk45n-logos-liblogos                 # headers (ABI-matching)
APP=/nix/store/44f5zpblschrw815y4wxybvqihps6il2-logos-standalone-app-1.0.0    # coherent lib + logos_host
QTBASE=/nix/store/dkfr32yi7p8cdxsnll05q1kax19fl7ay-qtbase-6.9.2
QTRO=/nix/store/r2cq6la02msp6kfcl9a17d2l2n96qpvs-qtremoteobjects-6.9.2
NLO=$(nix build nixpkgs#nlohmann_json --no-link --print-out-paths)

nix shell nixpkgs#gcc --command g++ -std=c++17 -fPIC "$HERE/muster_headless_host.cpp" \
  -I"$LL/include" -I"$LL/include/cpp" -I"$NLO/include" \
  -I"$QTBASE/include" -I"$QTBASE/include/QtCore" -I"$QTBASE/include/QtNetwork" \
  -I"$QTRO/include" -I"$QTRO/include/QtRemoteObjects" \
  -L"$APP/lib" -llogos_core -L"$QTBASE/lib" -lQt6Core -lQt6Network -L"$QTRO/lib" -lQt6RemoteObjects \
  -Wl,-rpath,"$APP/lib:$QTBASE/lib:$QTRO/lib" \
  -o "$HERE/muster_headless_host"

echo "built $HERE/muster_headless_host"
echo "run:  LOGOS_HOST_PATH=$APP/bin/logos_host python3 $HERE/drive.py $HERE/muster_headless_host <mods-dir> $APP/bin/logos_host <data-dir> <instance>"
