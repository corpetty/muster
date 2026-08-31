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

## Blocker 1 — SOLVED (2026-08-31): muster discarded delivery's token

The real runner spawns a **separate `logos_host_qt` process per module** (muster, delivery,
capability — all sharing `LOGOS_INSTANCE_ID`), so muster→delivery is IPC in the default
`remote` lp mode, and the registry URL (`local:logos_delivery_module_<id>`) resolves fine.
The failure was **not** transport/mode/re-entrancy — it was **tokens**.

muster's plugin statically embeds its own `liblogos_protocol` (lp_* are `T`) with its own
TokenManager, separate from the `logos_host_qt` loader's. The generated glue
**`logos_module_accept_token` (muster_gen.nim) was a NO-OP** — the loader hands muster a
token for each dependency it may call (delivery_module) and muster **discarded** it. So
muster's embedded lp had no token → delivery's ModuleProxy rejected every outbound
`lp_invoke`, returning in ~1ms with `ok=1 json=null` (the protocol conflates no-result with
a rejected call). `createNode` never ran; the Waku node never booted. Single-instance folds
still passed only because `session.publish()` writes the local log first.

**Fix:** `logos_module_accept_token` calls `lp_token_save(moduleName, token)`
(logos_protocol.h: "Store a token for module_name") into the plugin's embedded lp.
**Verified** — with the token saved: `createNode → {"error":null,"success":true,"value":null}`
and delivery dials all 6 fleet nodes (6 ESTABLISHED conns to `:30303`). Also made
`createNode`/`start`/`subscribe` **async** (`lp_invoke_async`) and deferred the topic
subscribe until `start` completes — correct regardless (they run inside `coordinate_join`'s
QRO dispatch), though the token was the actual blocker.

The fix is hand-added to the generated `muster_gen.nim` → **belongs in the module-builder
codegen template** (a regen would drop it). Debug the transport with `MUSTER_LP_DEBUG=1`
(stderr traces of createNode/start/subscribe/inbound/send results, in `delivery.nim`).

### Self-test rig (no GUI)
Run the real runner offscreen: `MUSTER_DELIVERY_CONFIG=<fleet cfg> MUSTER_AUTOJOIN_TOPIC=<topic>
QT_QPA_PLATFORM=offscreen .run/runner/bin/muster-ui --user-dir <dir>`. The auto-join hook
(`muster_ui_backend.cpp onContextReady`, env-gated) drives `coordinate_join` + `requestJoin`
and polls pending/members. The node-boot tell is `ss -tnp | grep :30303` on delivery's child
`logos_host_qt` pid (delivery's Waku logs go to *its* process stdout, not the main runner's).
Iterate from the working tree with `nix build path:.#runner --override-input muster_module
path:.../module` (the `path:` lock caches by lastModified; `touch` the sources to force a
re-read — do NOT `nix flake update muster_module`, it bloats ui/flake.lock).

## Blocker 3 (NEW, OPEN) — cross-host relay: both nodes on the fleet, zero frames cross

With Blocker 1 fixed, two instances (distinct `LOGOS_INSTANCE_ID`, same topic) each boot a
node and connect to all 6 fleet nodes — but **neither receives the other's frames** (`inbound
frame` count stays 0; `coordinate_pending` stays empty on both). Confirmed the subscribe now
fires in the right order (createNode → start → subscribe-after-start) and a valid Waku
content-topic format (`/app/version/name/enc`) doesn't change it. So discovery + transport +
subscribe all work, but the **relay/gossip layer isn't delivering edge→edge over the fleet**.
**Send is confirmed good, receive is the break:** with `MUSTER_LP_DEBUG=1`, B's `requestJoin`
publish returns `send/sub-result ok=1 {"success":true,"value":"<reqId>"}` — delivery accepted
and published it — yet A's `inbound frame` count stays 0. So the message leaves B's node fine;
the fleet just never delivers it to A.
Open hypotheses for the delivery/Waku team: the fleet nodes may not relay arbitrary
cluster-2 shards edge-to-edge (store/filter/lightpush-oriented), so muster may need
**lightpush to send + filter to receive** rather than relay `send`/`subscribe`; or the two
edge nodes need to mesh directly on the shard (peer exchange / direct dial) rather than rely
on the fleet to gossip between them. `MUSTER_LP_DEBUG=1` shows whether `send` succeeds
(send-side) vs whether frames arrive (receive-side). This is the last mile now.

### Blocker 3 narrowed (2026-08-31): relay DELIVERS, delivery never emits `messageReceived`

Deep strace of the runner's delivery process (`strace -f -e write` on the `logos_host_qt
--name delivery_module` pid) settled it. Two instances on one topic, on the fleet:

- **The fleet relays muster's traffic.** A's node logs `received relay message … topic=/waku/2/rs/2/5 contentTopic=/muster/1/…/proto` with B's `msg_hash`es (distinct from A's own sends). So B→fleet→A works at the Waku relay layer. The content topic autoshards to **shard 5** (`/waku/2/rs/2/5`).
- **delivery never surfaces it.** Over 45s, delivery's `event_callback` fires only `connection_change`, `message_propagated` (its own sends), `relay_topic_health_change` — **zero `message_received`**, so muster's `onMessageReceived` never runs (`inbound=0`, `coordinate_pending` empty on both). The whole `MessageSeenEvent → isSubscribed → MessageReceivedEvent` chain (v1.0.0 source) never runs; no "skipping … not subscribed" either.
- **Not muster's transport code.** Reverting the boot to fully synchronous (createNode/start/subscribe sync, event-sub after start — the proven chat ordering) behaves identically: `createNode {"success":true}`, `send` ok, **still `inbound=0`**. Async vs sync makes no difference; the token was the only thing that mattered for send.
- **Version + the known bug.** muster runs delivery_module **v0.2.0** (the source read above is v1.0.0 — receive internals may differ). `demo/poc/BUG-lgx-in-basecamp-cross-network-chat-fails.md` documents this exact "sends fine but never receives" pattern for chat, with the leading cause a peer **not relay-meshing a sparse shard** (chat's `/waku/2/rs/2/0`). muster's shard 5 shows repeated `getPubSubPeersInMesh - there is no mesh peer for the given pubsub topic` (sparse — only muster instances use it), so the gossip mesh never forms even though occasional messages arrive.

### Blocker 3 SOLVED (2026-08-31): store-based catchup — two instances converge over the fleet

Option (1) works. delivery's relay never surfaces the message (v0.2.0, sparse shard), but the
**fleet retains it in store**, and store is request/response — mesh-independent. muster now
polls the store for every subscribed topic (`delivery.nim`: `fireCatchup` fires an async
`storeQuery(jsonQuery, peerAddr, timeoutMs)` every ~8s; the store peer is the first
`entryNode`; `poll()` parses the response and dispatches each retained message through the
same handler as a live one — ingest dedups our own, R-2/R-4). **Verified end to end on the
logos.test fleet:** two runner instances on one topic each **see the other's join request**
(`coordinate_pending` → `pending=1` on both), ingesting 300+ store messages. That is real
cross-host delivery; the whole coordinate flow (admit/propose/contribute) rides the same
transport. (The offscreen self-test can't complete *admission* because `coordinate_admit`
enforces F-9 — the binding must recover to a Safe owner — and the random test identities
aren't owners; real owners pass it. That's correct product behaviour, not a transport gap.)

Store-response shape (fleet-confirmed): lp envelope `{"value":"<json>"}` → `value` parses to
`{"messages":[{"messageHash","message":{"vResultPrivate":{"contentTopic","payload":[byte,…]}}}]}`;
`payload` is a **byte array**, not hex/base64.

Follow-ups (quality, not correctness): time-window the store query (`timeStart`/cursor) instead
of re-fetching + deduping the whole topic each tick; rotate the store peer across all
`entryNodes` for resilience; the ~8s catchup interval is the cross-host latency floor (fine for
coordination, tune if needed). The parse depends on delivery's `vResultPrivate` serialization —
revisit on a delivery bump. Debug with `MUSTER_LP_DEBUG=1` + the offscreen self-test rig +
`strace -f -e write` on the delivery pid.

PR 202 (module-builder cdylib path) is unrelated, and its merged commit is **behind** the
local fork (the fork has 5 later commits muster needs) — do not switch to it.

Tracked under exo-e17. The token fix, the fleet resource, the async/deferred boot, and the
single-instance fold are done; cross-host relay over the fleet is the open item.
