# Logos delivery fleets — bootstrap peers for muster's transport

muster's transport is `logos-delivery` (an embedded Waku node). Two muster instances
converge only if their nodes can **discover each other**. The bundled `logos.test` preset
boots a node on cluster 2 but ships **no bootstrap peers** (`creating service discovery as
seed node (no bootstrap nodes)`), so two fresh nodes never meet.

The fix — the one the Status app uses — is to **piggyback off the public fleet**: point the
node at the live Logos delivery fleet as `entryNodes`. Both instances connect to the fleet,
and the fleet's relay gossips their messages between them. No direct peering, no multiaddr
lookup, no hand-run bootstrap node.

## The pinned sets

`logos.test.json` (cluster 2) and `logos.dev.json` (cluster 3) each carry a ready-to-use
delivery `createNode` config plus the raw node table (multiaddr / ENR / peer_id), extracted
from `https://fleets.logos.co/data.json` — the same JSON the fleets dashboard renders.
**Prefer `logos.test`**: it matches the cluster the `logos.test` preset already boots on.

Peer ids rotate when a node is re-keyed. When discovery starts failing, re-pin:

```bash
./infra/fleets/refresh.sh
```

## Pointing muster at the fleet

muster reads its delivery `createNode` config from the `delivery` setting (invariant 8 —
untrusted, user-configurable infra). Set it to the fleet config before joining a room:

```
muster_module.set_setting("delivery", <infra/fleets/logos.test.json .delivery_createNode_config>)
muster_module.coordinate_join("/muster/<room>")
```

The config is `{"mode":"Core","preset":"logos.test","entryNodes":[<6 fleet multiaddrs>]}`.
A host/runner should set this at startup, the way the demo UI defaults to
`kDefaultDeliveryPreset = "logos.test"` — muster itself stays infra-agnostic and defaults to
an isolated node.

## Verified

A delivery node booted with `logos.test.json`'s config connects to the fleet and relays live
cluster-2 traffic within seconds — observed receiving relay messages from
`node-01.do-ams3`, `node-01.ac-cn-hongkong-c`, and `node-02.gc-us-central1-a` on
`/waku/2/rs/2/{0,2}`. See `docs/labbook/two-instance-live-wire-blockers.md` for the run and
for why the *minimal headless host* still can't drive the muster→delivery path end to end
(its lp module→module bridge is unconfigured; the real runner is coherent there).
