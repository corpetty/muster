# Cross-network chat fails when muster_ui runs as a `.lgx` in Basecamp; the standalone build works

> **Update 2026-08-18 (same day): the layer changed.** The two-peer, cross-network demo **succeeds** when both peers run the **standalone** build (`logos-standalone-app` via `make alice`/`make bob`). It **fails** when a peer runs **`muster_ui.lgx` hosted inside logos-basecamp** — that peer sends fine but never receives, and the other peer never sees its messages. So the fault is in the **Basecamp-hosting path**, not the delivery fleet and not Muster's own code. The delivery/relay and store-archive symptoms in §3 were captured on the *failing Basecamp side* and are **not** confirmed as the cross-network blocker; they are kept as observations, demoted from the diagnosis. §1 is the isolation plan that would confirm the actual cause.

**Components:** `muster_ui.lgx` hosted by **logos-basecamp** (failing) vs. `logos-standalone-app` bundling the same UI (working). Underneath: `logos-chat-module` + `logos-delivery`. Local delivery build reported `agentVersion: logos-delivery-v0.38.1-gf8b036`; Logos test-fleet nodes report `logos-delivery-"b45df8"`.
**Host / preset:** `delivery_preset: logos.test`, cluster id **2**, x86_64-linux.
**Environment:** two peers on different networks, same `logos.test` fleet. One peer on standalone, one initially on lgx-in-Basecamp.
**Date measured:** 2026-08-18, ~11:30–11:34 EDT (Basecamp capture); standalone success confirmed later the same day.
**Severity:** the demo is deliverable **only** via the standalone build. Hosting muster_ui as a `.lgx` in Basecamp — the direction of the plan in commit `006760c` — currently cannot complete a cross-network chat.

---

## TL;DR

- **Works:** standalone ↔ standalone, across the network. Live chat delivered both ways.
- **Fails:** lgx-in-Basecamp ↔ standalone. The Basecamp peer's `send` reports success (`Message successfully sent`), but no message crosses in either direction.
- **Therefore:** the transport, the fleet, and Muster's payload are not the blocker. Something in **how Basecamp hosts the lgx** is. Not yet isolated.
- **Do not** re-file the §3 delivery/store symptoms as a fleet bug until the §1 comparison confirms them causal — they were seen only on the failing host and may be coincident fleet noise (a prior report on this project was retracted for exactly this pattern: two measurements agreeing on one misread value).

---

## 1. What would isolate the cause (the comparison to run)

Capture, for the **same attempt**, two console logs (see `demo/poc/` capture notes / `make ... | tee`):

- **A** — the Basecamp peer's **shared-delivery console** during a *failing* send/receive.
- **B** — a standalone peer's delivery console during a *working* exchange.

Then diff on two axes:

1. **Content topic.** For each chat send, delivery logs `contentTopic=/logos-chat/1/<hash>/proto`. **Do A and B publish/subscribe the same `<hash>` for the same conversation?** If they differ, the two peers are talking on different topics and will never see each other regardless of mesh health — this is the leading hypothesis, and it points at **chat-module / protocol-version skew** between what Basecamp ships and what the standalone bundles.
2. **Versions.** Compare `agentVersion: logos-delivery-vX` and the chat-module build on each side. Basecamp hosts its own shared chat + delivery modules across all Basecamp apps; the standalone bundles matched ones. A version gap here explains a topic gap.

Leading hypotheses, ranked:

1. **Content-topic / version skew** between Basecamp's shared modules and the standalone bundle → peers derive different `/logos-chat/1/<hash>/proto`, never meet. Best fits "standalone↔standalone works, Basecamp↔standalone silent."
2. **Basecamp's shared delivery node** doesn't relay-mesh chat shard `/waku/2/rs/2/0` (matches §3), whereas standalone's dedicated delivery does.
3. **Capability-policy / API seam** in Basecamp gating subscribe/receive. Least likely — the failing capture shows `send` and `subscribe` both completing.

Axis 1 is decisive and cheap: if the `<hash>` differs, stop looking at mesh/store.

---

## 2. What we measured (the layer split)

- **Standalone build, cross-network: works.** Both peers exchanged chat live. (Confirmed 2026-08-18.)
- **lgx-in-Basecamp, cross-network: fails.** In ~4 minutes of the Basecamp peer's log, outbound sends all report success, and there is **not one inbound `/logos-chat/…/proto` message**, while other shards' traffic (2/3/4/7 — radio-basecamp, logos, inference, kym) arrives continuously.

Outbound, from the Basecamp side:

```
11:31:12 chat_module::actions: created direct conversation 99f2bcf3efe37577595f56cc555733c2
11:31:12 DeliveryModuleImpl::send ... contentTopic: /logos-chat/1/da7ef4ad/proto
11:31:12 NTC start publish Waku message ... pubsubTopic=/waku/2/rs/2/0 contentTopic=/logos-chat/1/da7ef4ad/proto
11:31:16 INF Message successfully sent ... requestId=d24c1f074cfa2b1afbdd
```

The send side is happy on both builds. The difference is entirely on the receive/rendezvous side of the Basecamp host.

---

## 3. Symptoms observed on the failing Basecamp host (NOT confirmed causal)

Kept for reference. Any of these could be the mechanism, or could be coincident fleet noise — §1 decides.

### 3a. Chat shard shows no relay mesh (Basecamp side)

Chat rides `pubsubTopic=/waku/2/rs/2/0`. All session:

```
INF getPubSubPeersInMesh - there is no mesh peer for the given pubsub topic ... pubsubTopic=/waku/2/rs/2/0
event_callback: {"eventType":"relay_topic_health_change","pubsubTopic":"/waku/2/rs/2/0","topicHealth":"UnHealthy"}
```

Shard 0 flaps `MinimallyHealthy ↔ UnHealthy` and never holds a mesh peer, while relay traffic on shards 2/3/4/7 flows fine. **Open question:** does Basecamp's *shared* delivery node relay-mesh shard 0 at all, or does its many-app subscription set starve it? Standalone working suggests standalone's dedicated delivery meshed shard 0 — but we have not yet confirmed shard-0 `Healthy` in a standalone capture.

### 3b. Fleet store archive query fails

```
WRN store query failed, trying next peer  topics="waku store client"  peerId=16U*Q53BwG
  error="... archive error: DRIVER_ERROR: ... ERROR:  relation \"messages_lookup\" does not exist ... FROM messages_look"
WRN store query failed, trying next peer  ... peerId=16U*NqrKCj  (same error)
```

`relation "messages_lookup" does not exist` is a schema/migration gap on the `logos.test` **store node's** Postgres archive — a genuine server-side fault that disables history/offline recovery for the fleet. **But** since standalone succeeds via **live** relay, the store is not the cross-network blocker for a co-online demo. Worth reporting to the fleet operators on its own merits; not this bug's root cause.

### 3c. NAT / reachability (context, applies to both builds)

The local peer is behind symmetric NAT and undialable:

```
addrs: [/ip4/192.168.1.132/tcp/40521]
observable_address=ok(/ip4/173.42.114.210/tcp/52464)  → /44426 → /43942   (external port rotates)
dialMe timed out  topics="libp2p autonatservice"  "Timeout exceeded!"
random lookup complete  "waku service discovery"  found=0
```

This makes both peers depend on the fleet to rendezvous, and it held for the standalone attempt too — yet standalone worked. So NAT is a stakes-raiser, not the differentiator between the two builds.

---

## 4. Questions for the messaging / anon-comms team

1. **Basecamp module versions.** What chat-module and `logos-delivery` versions does the current Basecamp ship, vs. what `muster_ui.lgx` / the standalone runner are built against? Is a skew expected, and could it change the derived `/logos-chat/1/<hash>/proto` topic?
2. **Shared delivery + shard 0.** In Basecamp, delivery is shared across all apps and subscribes a large content-topic set. Is chat shard `/waku/2/rs/2/0` relay-meshed in that configuration, or can the shared subscription set leave it without mesh peers?
3. **Capability seam.** When muster_ui.lgx reaches delivery through the logos API under capability policy, is there any gate that would let `send`/`subscribe` succeed while inbound relay/filter delivery is silently dropped?
4. **(Independent) store schema.** `logos.test` store nodes error `relation "messages_lookup" does not exist`. Missing migration? Disables history/offline delivery fleet-wide even though it isn't this demo's blocker.
5. Is `logos-delivery-v0.38.1-gf8b036` (local) vs `b45df8` (fleet) a supported skew?

---

## 5. Where this leaves the demo and the plan

- **Demo:** deliver via the **standalone** build; it works cross-network.
- **Plan `006760c` (host muster_ui in Basecamp):** blocked on this — the Basecamp-hosted path does not complete a cross-network chat. Resolve §1 before treating Basecamp-hosting as demo-ready.

---

## Appendix: unrelated noise in the Basecamp capture

```
QQmlExpression: Expression .../MessageDelegate.qml:126:9 depends on non-bindable properties:
    QGradient::stops
    QQuickGradientStop::color
```

Cosmetic QML binding warning on the UI side; unrelated to delivery.

Local peer id for fleet-side correlation: `16Uiu2HAmD8SLn9zj6nRiEb2FfbjN3mVS6AWLULGr7DPL6N38jLZr` (`16U*38jLZr`).

---

*Contact:* Corey Petty — <corey@status.im>. Can re-run either build against the testnet, capture paired standalone-vs-Basecamp delivery consoles, and diff content topics / versions on request.
