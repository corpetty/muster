# Testnet v0.3: the day the fleet went away (2026-09-30)

Logos Testnet v0.3 launched on 2026-09-30. Its rollout took muster's two-instance
runs down for most of a day, and what fixed it was not in muster. Epic exo-eb6 is the
migration that followed.

## What we saw

Every two-instance self-test went red on every branch at once. `split-self-test.sh`
timed out at 184 s with nothing final, and peer B never got past `members=1`. Its log
had nothing but these:

```
Dialing failed … TcpTransport dial error: (111) Connection refused
DeliveryModuleImpl: Store query failed for peer: /dns4/node-01.ac-cn-hongkong-c.logos.test…
Failed to publish message with relay
```

The code had just changed (a rebase onto eight new PRs), so a regression looked likely.
It was not one.

## How to tell the fleet from the code

Probe the fleet's nodes **by IP**, from the fleet's own table. A remote host refusing a TCP
connect is not something muster can cause:

```bash
curl -sS https://fleets.logos.co/data.json -o /tmp/fleets.json
python3 - <<'EOF'
import json, socket
d = json.load(open('/tmp/fleets.json'))
for fleet in d:
    for host, v in d[fleet]['logos-node-delivery'].items():
        m = v['ServiceMeta']
        try: socket.create_connection((v['Address'], 30303), timeout=4).close(); r = 'open'
        except Exception as e: r = type(e).__name__
        print(fleet, host, r, m.get('image'), m.get('version'), 'cluster', m.get('cluster-id'), m.get('timestamp'))
EOF
```

`ServiceMeta` carries each node's image, nwaku version, cluster id and redeploy time.
That is how the rollout showed:

- **`logos.test` (cluster 2):** all six nodes refused :30303 by IP. The first one back,
  `node-01.do-ams3`, came back with a new image (`deploy-logos-test`, redeployed 21:07Z);
  the other five still listed delivery 0.2.1 metadata from August while refusing. It was
  a rolling upgrade, one node at a time.
- **`logos.dev` (cluster 3):** every node accepted the TCP connection, then dropped muster
  in the Waku metadata handshake (`waku metadata … Connection reading error: Stream
  Closed!`), so every store query failed (`ffi error: handleRes fireSync`). The fleet
  runs nwaku v0.39.0 on **cluster 3**. Delivery v0.2.0 still resolves the `logos.dev`
  preset to **cluster 2**: logos-delivery#4113 moved it, and the module's
  `networks.md` warns that an older build "will not reach the fleet".

## What still worked

muster's delivery v0.2.0 client kept working **through the one upgraded `logos.test`
node**. `two-instance-proof.sh` passed once and `split-self-test.sh` passed 3 of 3, in
24–33 s each. The same cluster still worked from the old client, and RLN was not
enforced yet.

## Why v0.2 cannot stay

Delivery **v0.3.0** (2026-09-30, nwaku v0.39.0) turns RLN on for the `logos.test` preset:

- **A v0.3 node there does not even `start`** without `liblogos_rln_module` ≥ 0.10.0 and
  `liblogos_lez_rln_module` ≥ 4.2.1 loaded and an **active RLN membership**. The RLN
  module makes the node its own LEZ wallet and registers once that wallet's payer holds
  ≥ 2×10⁸ native LEZ testnet (exo-eb6.3).
- **Proof validation follows about two weeks after launch.** The Logos blog put it at
  "roughly two weeks after release", so about 2026-10-14. After that, a v0.2 client's
  unproven messages are rejected on `logos.test`.

`logos.dev` runs no RLN, so delivery v0.3.0 on `logos.dev` is the path that needs
nothing more. muster moved its default there (exo-eb6.1, exo-eb6.2). `MUSTER_FLEET`,
`TRY_FLEET` and `make run-fleet FLEET=` still pick `logos.test`.

## Moving muster to delivery v0.3.0: six traps (2026-10-01)

Each one was found live, through `two-instance-proof.sh` and `split-self-test.sh` on
`logos.dev`, and each fix has a test in `module/tests/` where it can be held without a node.

1. **Neither builder can parse delivery v0.3.0's contract.** Its `.lidl` declares
   `optional_depends [libp2p_module, liblogos_rln_module]`. Both of muster's builders
   generate a wrapper from every dependency's `.lidl`: the UI's (basecamp's, ADR-013) and
   the module's (the codegen fork). Their LIDL parsers predate the keyword and stop:
   `Unexpected token 'optional_depends' in module body`. muster never calls delivery
   through that wrapper; the module calls it over raw `lp_*`. So each flake hands its
   builder the contract with that one line removed (`deliveryForUi`, `deliveryForModule`).
   The runner still bundles the real module, `packages.<sys>.lgx`, untouched.
2. **`messageReceived` gained `source` before `timestamp`.** It went from
   `(messageHash, contentTopic, payload, timestamp)` to `(…, payload, source, timestamp)`.
   Read by position, every v0.3 message's timestamp was the string `"live"`, read as 0
   (`transport/received.nim`, `delivery_received_test`).
3. **One bare top-level key pins the port.** v0.3 reads a config of layered keys
   (`preset`, `mode`, `messagingOverrides`) with OS-assigned ports. A bare key beside
   them, as muster's `entryNodes` was, switches it to the legacy flat shape, whose TCP
   port defaults to 60000. A second instance on the same machine then failed to start
   (`START_NODE failed`). v0.3's presets carry their own entry nodes, so muster now keeps
   them for itself only, as store peers (`transport/node_config.nim`,
   `delivery_node_config_test`). From here every QUIC dial to `logos.dev` timed out, so
   QUIC is off unless `MUSTER_DELIVERY_QUIC=1`.
4. **A store query that cannot dial says so with no request id.** The answer is
   `{"error": "…PEER_DIAL_FAILURE: <peer id>", "success": false}`. muster's catch-up never
   saw these, kept rotating through dead peers, and waited out a 10 s timeout on each
   history page lost to one. The peer is now backed off: skipped for 5 s, doubling to a
   minute, cleared by an answer (`store_catchup_test` §10).
5. **Stored payloads are base64 now.** A store answer's message comes back unwrapped (no
   `vResultPrivate`), its payload a standard-base64 string where v0.2 sent an array of
   byte values. muster read only the array, so store catch-up recovered nothing; that is
   what broke the split self-test (`delivery_received_test` §4).

6. **muster's own store polling stalled the module.** muster asked every topic's
   store window each second, because on v0.2 the store was the only way to receive. With
   five of six store peers unreachable, each query held the delivery module on a dead
   dial for up to 5 s, sends queued behind it, and the handshake failed one run in three,
   in a "pass, pass, fail" pattern that looked like rate limiting but survived a
   cool-down. With store queries made rare it passed 4 of 4, faster. Now a topic's history
   is still paged at full speed, but its sliding window is asked every 15 s
   (`MUSTER_CATCHUP_WINDOW_MS`), and one query may hold delivery at most 3 s
   (`MUSTER_STORE_TIMEOUT_MS`) (`store_catchup_test` §11).

7. **The fleet moved on and v0.3.0's own catch-up fell behind it** (2026-10-08,
   exo-dcc.12). From 2026-10-02 the `logos.dev` store nodes refuse any query whose time
   range is longer than 24 h (logos-delivery#4349). Delivery v0.3.0's own startup
   catch-up asks for just over 24 h on every first launch, so it is refused on every
   pass. Muster's own queries never name such a range. muster now pins delivery v0.3.2,
   which walks that range in windows of at most 24 h. Details:
   `store-24h-rule-and-the-lost-relaunch.md`.

One thing v0.3 fixed for us: **live receive works**. v0.2.0's relay never surfaced a
received message on muster's shard (blocker 3 in `two-instance-live-wire-blockers.md`),
so cross-host receive rode store polling alone. On v0.3.0 both peers log `inbound
source=live` frames, and store catch-up fills the gaps.

Where it stands, with five of `logos.dev`'s six nodes still unreachable from here:
`two-instance-proof.sh` passed 4 of 4 (23 s each) and `split-self-test.sh` 4 of 4 (36–41 s),
and `scripts/ui-parity.sh` was 8 of 8 green, each test faster than before the upgrade.

## The second outage, and parity without the fleet (2026-10-01, afternoon)

From about 11:50 EDT, 10 of the 12 entry nodes across `logos.dev` and `logos.test` dropped
:30303 by IPv4 (the recipe above). The hosts were up, since :8000 on the same hosts
answered with a reset, and outbound :30303 from here worked (portquiz.net). The one
`logos.dev` node that still took TCP refused the libp2p dial. One `logos.test` node
answered under a key that `fleets.logos.co` did not list yet ("Noise handshake, peer id
don't match"), so the registry, not muster's pin, was stale. Every two-instance
self-test went red with no code at fault. (Resolving a node by name can also give its
IPv6 address, and with no v6 route that fails "network unreachable": probe the IPv4
address from the table.)

**`MUSTER_FLEET=local`** (exo-eb6.7) runs the self-tests with no fleet. The instances make
a network of their own on this host, in delivery's own e2e shape (`tests/e2e/libs/helpers.py`
`make_delivery_config`): cluster 198, one shard, relay only, each node on a free
127.0.0.1 port. The first instance a test launches is the hub. `ui_peer_config` reads the
hub's address from delivery's "Started libp2p node" line, about 3 s after launch, and
each later instance dials it (`staticnodes`). A config with no preset passes to delivery
verbatim (`node_config.nim`). `MUSTER_FLEET=local scripts/ui-parity.sh` went 8 of 8 green
in about 2 minutes, during the outage.

What it proves and what it does not: the room's code end to end between two real
runners (handshake, invite, both splits, settlement). Not the fleet, discovery, or store
catch-up: with no store node, receipt is live only. The fleet runs stay the live check;
the local run says whether a red fleet run is the fleet.

## Sources

- Logos Testnet v0.3 announcement: <https://blog.logos.co/article/logos-testnet-v03-live>
- Delivery v0.3.0 release notes, and `docs/pages/{rln,networks,run-node}.md` at the tag:
  <https://github.com/logos-co/logos-delivery-module/releases/tag/v0.3.0>
- The live fleet table: <https://fleets.logos.co/data.json>
