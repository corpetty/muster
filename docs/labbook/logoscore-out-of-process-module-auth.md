# The live two-instance run is blocked by logoscore's out-of-process module auth (2026-08-26)

Attempting the live two-instance run (two real hosts, two delivery nodes, over the
wire) I got the whole headless stack standing **except the last inch**: muster_module
cannot call delivery_module inside the `logoscore` daemon. Root cause pinned below so
the next attempt starts from the fix, not the search.

## What worked (the headless stack stands up)

- **Both modules load headless in `logoscore`.** Built the portable delivery `.lgx`
  (`nix build github:logos-co/logos-delivery-module/v0.2.0#lgx-portable`), but the
  logoscore daemon is a **-dev build** — it wants `linux-amd64-dev` variants, so the
  working modules-dir is a copy of the runner's already-unpacked bundled modules
  (`…-logos-muster_ui-plugin-dir-modules/{muster_module,delivery_module}`), which are
  `-dev` with their dep libs co-located.
- `logoscore --config-dir <C> daemon -m <mods> --persistence-path <C>/data` →
  `load-module muster_module` loads it **and** `delivery_module` as its dependency →
  `call muster_module health` returns `ok`. First confirmation muster runs headless in
  logoscore on this box.
- `coordinate_join` is callable end to end and returns `{address, topic}` — the module
  logic runs; the persistence keystore opens; the delivery node boot is *attempted*.

## The wall

`coordinate_join` returns OK but the delivery node never actually boots. The daemon log:

```
[muster_module] LogosAPIClient: token for "delivery_module" rejected by provider; re-exchanging and retrying once
[capability_module] ModuleProxy: rejecting unauthorized call to "requestModule" - auth token not recognized
[delivery_module]   ModuleProxy: rejecting unauthorized call to "createNode"   - auth token not recognized
```

`coordinate_join` swallows it because `delivery.nim` does `discard invoke("createNode", …)`.

The chain:
1. muster's `LogosAPIClient` calls delivery; delivery's `ModuleProxy` rejects the token.
2. muster tries to **re-exchange** — call `capability_module.requestModule` for a fresh
   delivery token — and *that* is rejected too: **"auth token not recognized"**.
3. So muster can obtain **no** inter-module token at all, and every call to delivery
   (`createNode`/`start`/`send`/`subscribe`) fails.

The rejection is at the `ModuleProxy` `isAuthorized()` layer, which "accepts ANY issued
token" — so muster is being told it holds **no recognized token**, not that it's
disallowed. This is **independent of `--access-policy`**: capability_module's policy
gate is *fail-open when `m_restrictions` is empty* (see its `requestModule`), and
supplying a policy only added restrictions, it did not grant muster a token. The block
is the cross-process token handshake, not the allowlist.

## Why the runner works but the daemon doesn't

`logos-standalone-app` (the runner's host) loads modules **in-process** and calls
`logos_core_set_access_policy(nullptr)` — enforcement off, one auth context, no
cross-process token exchange (see the basecamp `app/main.cpp`: *"Access policy
temporarily disabled (allow all) … UI plugins are loaded out-of-process and aren't
tracked … so they're never in a module's allowed-caller set and get denied"*).
`logoscore` loads each module **out-of-process** (`logos_host` per module) with the
capability gate live, and there is **no flag** to run in-process or disable the gate
(`--module-transport` only picks the wire protocol; `--access-policy` is fail-open when
empty yet muster still holds no recognized token). The logoscore docs even say policy
enforcement "is currently a no-op" — so this daemon build is **version-skewed** ahead of
its own docs, and likely ahead of the logos-cpp-sdk muster's plugin was built against
(ADR-013 builds muster-ui on basecamp's coherent builder, a *different* SDK rev than
this logoscore). A protocol/SDK skew in the out-of-process token exchange is the most
likely culprit for "token not recognized".

## What this means, and the ways forward

The two-instance **logic** is proven (`two_instance_test`, over `LocalTransport`). The
*live-over-a-real-delivery-node* run is blocked by the **host**, not by muster. Options,
cheapest first:
1. **A logoscore lever** — an in-process module mode, or a documented way to disable the
   capability gate (the standalone app's `set_access_policy(nullptr)` equivalent). This
   is the clean fix and is upstream's to add.
2. **Rebuild muster_module against this logoscore's logos-cpp-sdk rev** so the
   out-of-process token handshake matches, then the capability gate is fail-open and the
   call succeeds. A build-config reconciliation (which SDK the module's plugin links).
3. **A tiny in-process headless host** using the logos-core C API with
   `logos_core_set_access_policy(nullptr)` + in-process load, exposing a method-invoke —
   i.e. a headless twin of `logos-standalone-app`. Real work: module method invocation
   goes through the LogosAPI client, not a bare C call.

Until one of those lands, the live two-instance run stays infra-bound — but now with a
named cause, not a shrug.

## Follow-up: the coherent own host (2026-08-26)

Chosen path (over pinning to logoscore's SDK): **build our own headless host from a
coherent logos-core**, in-process with the capability gate OFF — so there's no
cross-process token skew. Landed as `module/tools/headless-host/` (see its README).

**Result:** the host compiles against the standalone-app's own logos-core (the coherent
one the runner uses with these `-dev` modules) and **loads `muster_module` +
`delivery_module` in-process with `set_access_policy(nullptr)` and NO capability
rejection** — the exact barrier that stopped the `logoscore` daemon is passed for
loading. `[host] load muster_module -> 1`, no "token not recognized".

**Remaining inch:** invoking a module method returns `object_unavailable` — the core's
`LogosAPIClient` can't yet acquire the module's QRemoteObjects object. The `logoscore`
daemon does this by standing up a `core_service` provider (`LogosAPI("core_service",
coreTransports)` + `CoreServiceImpl`) as the registry/router and registering module
transports/tokens; replicating that (or the minimal acquire path) finishes the harness.
Ingredients + the exact build recipe are captured in the host's README so this resumes
from knowledge, not search.

## SOLVED: the coherent host now drives muster headless (2026-08-26)

`module/tools/headless-host/` **works** — it loads muster + delivery in-process with the
gate off and invokes methods (`health`→`ok`, `identity`/`describe` return real JSON). The
six things that had to line up (each a dead end until fixed) are in the host's README; the
last two were the sharp ones: (5) `callRemoteMethod` is still ModuleProxy-gated, so a
recognized token from `logos_core_get_token(module)` is required even with policy off; and
(6) `waitForFinished` inside `app.exec()` mis-delivers the QRO reply (double-nested event
loop) — a `QRemoteObjectPendingCallWatcher` firing from the main loop is the fix. The
registry-suffix mismatch (`LOGOS_INSTANCE_ID`) was the other non-obvious one. This unblocks
the two-instance live run: two hosts with distinct `--instance` ids + peered delivery nodes.
