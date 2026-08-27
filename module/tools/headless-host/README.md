# muster-headless-host — a coherent, owned host that drives muster headless

A small headless logos-core host that loads `muster_module` (+ its `delivery_module`
dependency) **in-process with the capability gate OFF** and **invokes its methods** —
the "coherent own host" path for running/testing muster regardless of logos-core stack
churn. Module and host use the same logos-core, so there's no SDK/token skew (the wall
that stopped the out-of-process `logoscore` daemon — see
`docs/labbook/logoscore-out-of-process-module-auth.md`).

## It works

```
$ python3 drive.py <host> <mods-dir> <logos_host> <data-dir> <instance>
health   -> OK	ok
identity -> OK	{"address":"0x368e…","ed25519":"0x56ad…","x25519":"0x7a9d…"}
describe -> OK	{"chainId":31337,"safe":"0x5FbDB2…","threshold":2,…}
```

Real module results, headless, no display, no daemon.

## Protocol

stdin: one call per line, tab-separated — `<module>\t<method>\t<arg1>\t<arg2>…`.
stdout: `OK\t<result>` / `ERR\t…`, printed asynchronously when the reply arrives. The Qt
event loop runs continuously so delivery's async transport pumps — what a two-instance
run needs. `drive.py` is a reference driver (spawn, send, read replies).

## The mechanism (what it took)

Six things had to line up — each was a dead end until fixed:

1. **In-process, gate OFF.** `logos_core_set_access_policy(nullptr)` — no cross-process
   token enforcement (the standalone-app's model). Set before `logos_core_start()`.
2. **`logos_core_init(argc, argv)`** first (sets up the core's QRemoteObjects registry).
3. **`LOGOS_INSTANCE_ID`** — the module publishes its object at a per-instance registry
   `local:logos_<module>_<LOGOS_INSTANCE_ID>`. `logos_host` (spawned by the core) and our
   consumer must agree on the suffix, so we `qputenv` it before anything reads it.
   `--instance` makes two hosts use distinct sockets (the two-instance handle).
4. **Raw QRemoteObjects acquire.** The `LogosAPIClient` wrapper's `requestObject` fails
   headless; a plain `QRemoteObjectNode` + `acquireDynamic(module)` + `waitForSource`
   succeeds. Replicas are pre-acquired at startup (acquiring inside a stdin callback hits
   nested-event-loop re-entrancy).
5. **A recognized token.** `callRemoteMethod(token, method, args)` is gated by the
   ModuleProxy (accepts any *issued* token even with policy off); `logos_core_get_token(
   module)` supplies one.
6. **Fully async reply.** `waitForFinished` inside `app.exec()` mis-delivers the QRO
   reply (double-nested loop). A `QRemoteObjectPendingCallWatcher` fires from the main
   loop instead — this was the final blocker.

`LOGOS_HOST_PATH` must point at a coherent `logos_host`.

## Build (current — machine-pinned; nixify next)

Coherent ingredients found on this box (see `build.sh`): logos-core lib + `logos_host`
from the standalone-app (`…-logos-standalone-app-1.0.0`, the one the runner uses with
these `-dev` modules); ABI-matching headers from `…-logos-liblogos/include`; Qt 6.9.2
(`qtbase` + `qtremoteobjects`); `nlohmann_json`. Run `./build.sh`.

**Coherence TODO:** a nix derivation in muster's flake that pulls the logos-core lib +
headers from the **same builder pin** the module uses (coherent by construction, no
hand-picked store paths), exposed as e.g. `apps.headless-host`.

## Two-instance live run — attempted, blocked on infra (see labbook)

Driving two hosts (`--instance` A/B, separate `--persistence`) through join → request_join →
admit → propose → intents was attempted end to end. It is blocked by two **infrastructure**
gaps, not muster logic — both diagnosed in
`docs/labbook/two-instance-live-wire-blockers.md`:

1. **muster's lp→delivery bridge doesn't boot the Waku node in this host.** Direct
   `createNode` on `delivery_module` via QRO boots a full node (66 lines of Waku logs);
   muster's `coordinate_join` with the same config emits none — `lp_invoke("createNode")`
   never reaches liblogosdelivery here. Single-instance folds still work because
   `publish()` writes the local log first, so that success never exercised the node.
2. **The bundled `logos.test` preset ships no bootstrap nodes** (`creating service discovery
   as seed node (no bootstrap nodes)`), so two seed nodes can't discover each other without
   hand-set `entryNodes` — and reading A's multiaddr via `getNodeInfo` over QRO hangs behind
   delivery's thread-blocking `start()`.

Unblocking needs a reachable delivery bootstrap node (+ its ENR in `entryNodes`) and/or
host-side lp-bridge wiring. Tracked under exo-6bc.
