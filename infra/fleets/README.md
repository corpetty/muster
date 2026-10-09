# Logos delivery fleets — bootstrap peers for muster's transport

muster's transport is `logos-delivery` (an embedded Waku node). Two muster instances
converge only if their nodes can **discover each other**. A bare delivery preset (`logos.test`
boots a node on cluster 2) ships **no bootstrap peers** (`creating service discovery as
seed node (no bootstrap nodes)`), so two fresh nodes never meet.

The fix — the one the Status app uses — is to **piggyback off the public fleet**: point the
node at the live Logos delivery fleet as `entryNodes`. Both instances connect to the fleet,
and the fleet's relay gossips their messages between them. No direct peering, no multiaddr
lookup, no hand-run bootstrap node.

## The pinned sets

`logos.test.json` (cluster 2) and `logos.dev.json` (cluster 3) each carry a ready-to-use
delivery `createNode` config plus the raw node table (multiaddr / ENR / peer_id), extracted
from `https://fleets.logos.co/data.json` — the same JSON the fleets dashboard renders.
Use the set that matches the preset the node boots on.

**The default is `logos.dev`** (cluster 3, no RLN; exo-eb6.2). Since Testnet v0.3 (delivery
v0.3.0), a node on `logos.test` sends nothing until it holds an active, funded RLN
membership, so muster stays on `logos.dev` until the room gifter lands and the default
moves (`docs/design/rln-membership.md` §7, slice R4). `MUSTER_FLEET` / `FLEET=` pick
`logos.test`.

Peer ids rotate when a node is re-keyed. When discovery starts failing, re-pin:

```bash
./infra/fleets/refresh.sh
```

## Pointing muster at the fleet

muster reads its delivery `createNode` config from the `delivery` setting (invariant 8 —
untrusted, user-configurable infra). Set it to the fleet config before joining a room:

```
muster_module.set_setting("delivery", <infra/fleets/logos.dev.json .delivery_createNode_config>)
muster_module.coordinate_join("/muster/<room>")
```

The config is `{"mode":"Core","preset":"logos.dev","entryNodes":[<6 fleet multiaddrs>]}`.
The module defaults to this very config: an embedded logos.dev preset with its entry nodes
(`DefaultFleet` in `module/nim-lib/muster_module.nim`), so a room connects with no setup.
`set_setting("delivery", "logos.test")` takes the short name too. A host or runner can still
set another at startup (`MUSTER_DELIVERY_CONFIG`, as `make run-fleet` does for
`FLEET=logos.test`), and a delivery config saved in Settings always wins.

## Verified

On 2026-09-01 (delivery v0.2.0, before the v0.3 default moved to `logos.dev`), a delivery
node booted with `logos.test.json`'s config connected to the fleet and relayed live
cluster-2 traffic within seconds — observed receiving relay messages from
`node-01.do-ams3`, `node-01.ac-cn-hongkong-c`, and `node-02.gc-us-central1-a` on
`/waku/2/rs/2/{0,2}`. See `docs/labbook/two-instance-live-wire-blockers.md` for the run and
for why the *minimal headless host* still can't drive the muster→delivery path end to end
(its lp module→module bridge is unconfigured; the real runner is coherent there).
