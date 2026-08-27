# muster-headless-host — a coherent, owned host for the two-instance live run

A small headless logos-core host that loads `muster_module` (+ its `delivery_module`
dependency) **in-process with the capability gate OFF** (`logos_core_set_access_policy(
nullptr)`), then drives it through a stdin REPL — the "coherent own host" path chosen
for making muster runnable/testable regardless of logos-core stack churn. Module and
host use the same logos-core, so there's no SDK/token skew (the wall that stopped the
out-of-process `logoscore` daemon — see `docs/labbook/logoscore-out-of-process-module-auth.md`).

## Protocol

stdin: one call per line, tab-separated — `<module>\t<method>\t<arg1>\t<arg2>…`.
stdout: `OK\t<result>` or `ERR\t<code>\t<message>` per line. The Qt event loop keeps
running between calls, so delivery's async transport pumps — what a two-instance run needs.

```
muster_module<TAB>set_setting<TAB>delivery<TAB>{"mode":"Core","relay":true,"tcpPort":60010,"clusterId":1,"numShardsInNetwork":8}
muster_module<TAB>coordinate_join<TAB>/muster/1/liverun/proto
```

## Status (2026-08-26)

**Works:** builds against the coherent logos-core, loads `muster_module` + `delivery_module`
in-process (via `logos_host`, `LOGOS_HOST_PATH`), auth OFF — **no capability rejection**,
which is the whole point (logoscore rejected `muster→delivery` with "token not recognized";
this host does not). `[host] load muster_module -> 1`.

**Remaining inch:** invoking a module method returns `object_unavailable` ("failed to
acquire remote object 'muster_module'"). The core's `LogosAPIClient` can't yet acquire
the module's QRemoteObjects object. The daemon (`logoscore` src `daemon/daemon.cpp`)
does more setup that this host omits: it stands up a **`core_service`** provider
(`LogosAPI("core_service", coreTransports)` + `CoreServiceImpl`) that acts as the
registry/router, registers operator tokens, and sets `logos_core_set_module_transports`
for `capability_module`/`core_service`. Replicating the `core_service` provider (or
finding the minimal acquire path) is the finish line.

## Build (current — machine-pinned; nixify next)

The coherent ingredients found on this box (see the commit that added this):
- logos-core lib + `logos_host`: the standalone-app's own (`…-logos-standalone-app-1.0.0`)
  — the one the runner uses with these exact `-dev` modules.
- headers (ABI-identical): `…-logos-liblogos/include` (`logos_core.h`, `logos_api*.h`,
  `logos_transport_config*.h`, `Timeout` era).
- Qt 6.9.2 (`qtbase` + `qtremoteobjects`), `nlohmann_json`.

```bash
g++ -std=c++17 -fPIC muster_headless_host.cpp \
  -I<liblogos>/include -I<nlohmann>/include \
  -I<qtbase>/include -I<qtbase>/include/QtCore -I<qtbase>/include/QtNetwork \
  -I<qtro>/include -I<qtro>/include/QtRemoteObjects \
  -L<standalone-app>/lib -llogos_core \
  -L<qtbase>/lib -lQt6Core -lQt6Network -L<qtro>/lib -lQt6RemoteObjects \
  -Wl,-rpath,<standalone-app>/lib:<qtbase>/lib:<qtro>/lib -o muster_headless_host

LOGOS_HOST_PATH=<standalone-app>/bin/logos_host \
  ./muster_headless_host --modules-dir <mods-dev> --persistence <data>
```

**Coherence TODO:** turn this into a nix derivation in muster's flake that pulls the
logos-core lib + headers from the **same builder pin** the module uses (so it's coherent
by construction, no hand-picked store paths), exposed as e.g. `apps.headless-host`.

## Two-instance plan (once invoke lands)

Two hosts, two persistence dirs, two delivery nodes peered on localhost (A: `tcpPort`
60010; B: 60011 with A's multiaddr from `delivery_module.getNodeInfo` as `entryNodes`).
Drive: A `coordinate_join` + `coordinate_propose`; B `coordinate_request_join`; A
`coordinate_admit`; B `coordinate_contribute`; both `coordinate_intents` → converge.
Kill A mid-collection, restart, confirm the contribution still lands (R-4/R-6).
