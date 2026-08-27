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

## What would unblock it

One of:
1. A running delivery **bootstrap/store node** on a reachable network + its ENR/multiaddr
   in `entryNodes` — then both muster nodes discover each other (closes blocker 2; still
   needs blocker 1).
2. Host-side lp-bridge wiring so muster's `lp_invoke("createNode")` actually boots the node
   (closes blocker 1), **plus** a way to read A's multiaddr for local `entryNodes` peering
   — either a muster method that surfaces `getNodeInfo`, or an async QRO read that doesn't
   sit behind delivery's blocked `start`.

Both are infra/integration, tracked under exo-6bc. The headless host itself — the reusable,
stack-change-resistant driver — is done and landed; this is the last mile to a live wire.
