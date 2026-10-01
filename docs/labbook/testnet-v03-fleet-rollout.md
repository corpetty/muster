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

## Sources

- Logos Testnet v0.3 announcement: <https://blog.logos.co/article/logos-testnet-v03-live>
- Delivery v0.3.0 release notes, and `docs/pages/{rln,networks,run-node}.md` at the tag:
  <https://github.com/logos-co/logos-delivery-module/releases/tag/v0.3.0>
- The live fleet table: <https://fleets.logos.co/data.json>
