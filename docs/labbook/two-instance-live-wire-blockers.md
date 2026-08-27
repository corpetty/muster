# Two-instance live wire: what actually blocks it (2026-08-26)

The coherent headless host (`module/tools/headless-host/`) drives muster's full method
surface headless, including the **single-instance** coordinate fold (join → propose →
`coordinate_intents` returns the proposal with a re-derived `safeTxHash`, threshold 2).
Attempting the **two-instance live wire** — two real hosts converging on an intent over a
real delivery/Waku network — surfaced two concrete blockers, both infrastructure, neither
in muster's own logic.

## Blocker 1 — muster's lp→delivery bridge doesn't boot the Waku node in this host

`coordinate_join` → `newDeliveryTransport(gDeliveryConfig)` → `lp_client_create(
"delivery_module", ...)` + `lp_invoke("createNode", cfg)`. In the standalone-app / basecamp
this boots a Waku node. In the minimal headless host it does **not**:

- Direct `createNode` on `delivery_module` **via QRO** (the host's own replica) boots a
  full node — 66 lines of liblogosdelivery logs to process stdout (`[out] [delivery_module]`
  … relay mounted, sharding, rendezvous, peer exchange).
- muster's `coordinate_join` with the **same** config emits **zero** Waku logs — only the
  module-init lines. liblogosdelivery re-emits its stdout through the module log regardless
  of caller, so the total absence means muster's `lp_invoke("createNode")` never reached
  liblogosdelivery's createNode. muster ignores createNode's result
  (`discard result.invoke(...)`), so the failure is silent.

The single-instance fold still works because `session.publish()` writes to the local log
**before** broadcasting (CLAUDE.md) — the fold never needed the node. So single-instance
success is not evidence the node booted.

Read: the `lp_*` in-process module→module bridge needs host-side wiring the standalone app
provides and this bespoke host does not. Fixing it means replicating logos-core's lp
routing setup in the host — a real investigation, not a one-liner. The QRO path (how the
host calls muster) is unaffected and works.

## Blocker 2 — the shipped `logos.test` preset has no bootstrap nodes

Even with a booting node, discovery fails. `createNode {"mode":"Core","preset":"logos.test"}`
logs: **`creating service discovery as seed node (no bootstrap nodes)`** (clusterId 2,
AutoSharding 8 shards). Two independent seed nodes with no bootstrap and no shared
`entryNodes` never find each other. The demo (`demo/muster-ui`, `kDefaultDeliveryPreset =
"logos.test"`) peers because it runs against a live logos.test network with reachable
bootstrap infra; this box's bundled preset ships none.

The self-hosted alternative (`{"clusterId":16,"relay":true,"tcpPort":600xx}`) boots a node
whose peer B could dial via `entryNodes:["/ip4/127.0.0.1/tcp/60010/p2p/<A-peerid>"]` — but
that needs A's multiaddr, and `getNodeInfo` **via QRO hangs**: delivery's `start()` blocks
the module's dispatch thread inside `app.exec()`, so subsequent QRO calls to delivery get
no reply (`getAvailableNodeInfoIDs` returns empty / no reply). muster reaches `start` over
lp (async) and doesn't hit this, but the host's QRO read of the multiaddr does.

## Blocker 2 — SOLVED by piggybacking off the Logos fleet (2026-08-27)

The bundled `logos.test` preset ships no bootstrap peers, but the public **Logos delivery
fleet** does. `https://fleets.logos.co/data.json` (the same JSON the fleets dashboard renders,
mirroring `fleets.status.im`) lists the `logos-node-delivery` service: `logos.test` = cluster
2 (6 nodes across ams3/us-central1/hongkong), `logos.dev` = cluster 3. Pinned into
`infra/fleets/{logos.test,logos.dev}.json` (+ `refresh.sh`), each with a ready delivery
`createNode` config: `{"mode":"Core","preset":"logos.test","entryNodes":[<6 fleet
multiaddrs>]}`.

**Verified end to end at the delivery layer:** a node booted with that config connects to the
fleet and relays live cluster-2 traffic within seconds — observed `received relay message`
from `16U*NqrKCj` (node-01.do-ams3), `16U*XGDqRF` (node-01.hongkong), `16U*yCHXR7`
(node-02.us-central1) on `/waku/2/rs/2/{0,2}`. So two muster nodes both pointed at the fleet
discover each other through the fleet's relay — no direct peering, no multiaddr lookup. The
preset's cluster (2) already matches the fleet, so only the missing `entryNodes` had to be
supplied. See `infra/fleets/README.md`. `logos.test` preferred (matches the preset cluster).

## Blocker 1 — refined: the minimal host doesn't configure muster's embedded lp

`coordinate_join` returns in **0.05s** (instant fail, not a 5s timeout), so muster's
`lp_invoke("createNode")` resolves its transport immediately to failure — it isn't reaching
delivery at all. Why: `nm -D` on `muster_module_plugin.so` shows `lp_client_create` /
`lp_invoke` as **`T` (defined, statically embedded)**, not `U` — muster carries its **own**
`liblogos_protocol` with its **own** process-global lp state, disconnected from logos-core's
module registry (where delivery is published, and where a direct QRO `createNode` reaches it).
muster never binds `lp_set_mode`/`lp_set_default_transport`, so it relies on the loader/host to
configure that embedded lp; host-side `lp_set_mode` is useless (different copy). The signature
is *not* mismatched — the current header's `lp_client_create(target, origin, targetTransport,
capTransport)` matches muster's 4-arg binding. The real runner (standalone-app / basecamp)
configures muster's embedded lp through logos-core's module-process wiring; the minimal
in-process host does not, and replicating that wiring is the open work.

## What remains

- **Live two-instance run:** use the **real runner** (`ui/flake.nix#runner` / `make run`,
  the coherent standalone app that wires muster→delivery correctly) with the fleet delivery
  config from `infra/fleets/logos.test.json`. Discovery is now solved; the runner handles the
  lp bridge. The GL-less box blocks the *UI render*, not the delivery/coordinate layer.
- **Or** fix the minimal host: configure muster's embedded lp at load (the logos-core
  module-transport wiring the standalone app does) — then the headless host drives the whole
  two-instance flow itself.

Tracked under exo-e17. The headless host, the fleet resource, and the single-instance
coordinate fold are done and landed; this is the last mile to a live wire.
