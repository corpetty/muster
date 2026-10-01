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

## Moving muster to delivery v0.3.0: five traps (2026-10-01)

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

One thing v0.3 fixed for us: **live receive works**. v0.2.0's relay never surfaced a
received message on muster's shard (blocker 3 in `two-instance-live-wire-blockers.md`),
so cross-host receive rode store polling alone. On v0.3.0 both peers log `inbound
source=live` frames, and store catch-up fills the gaps.

Where it stands: `two-instance-proof.sh` passes on `logos.dev`. `split-self-test.sh`
passed 2 of 3 in 49 s each. The third run failed in the handshake while five of the six
`logos.dev` nodes were unreachable from here and each peer held one relay connection.

## Sources

- Logos Testnet v0.3 announcement: <https://blog.logos.co/article/logos-testnet-v03-live>
- Delivery v0.3.0 release notes, and `docs/pages/{rln,networks,run-node}.md` at the tag:
  <https://github.com/logos-co/logos-delivery-module/releases/tag/v0.3.0>
- The live fleet table: <https://fleets.logos.co/data.json>
