# The mixnet on delivery 0.3: what it carries for muster's rooms (2026-10-08)

exo-dcc.4 asked one question before the Monero campaign could say anything about a
mixnet: does turning delivery's mix path on work for muster's rooms on delivery 0.3.x,
and what does it hide? Short answer: **it works, for sends, on `logos.dev`.** Every room
message both instances sent went out over the mixnet, and two instances converged as
they do without it. It hides **who published** a message. It does not hide **who reads**
a room, because reading is a store query that leaves from the reader's own address.
muster now has a `mix` setting, off by default, and a status row for it.

## What delivery 0.3 provides

Delivery v0.3.0 (logos-delivery `ca28145`, nwaku v0.39.0) added "sender anonymity through
Mix" (logos-delivery #4180). It is one `createNode` option, inside `messagingOverrides`
beside a preset:

```json
{"mode":"Core","preset":"logos.dev",
 "messagingOverrides":{"anonymityLevel":"Preferred"}}
```

- `None` is the default and mounts nothing. muster never set the option before this, so
  no muster build until now sent anything over mix.
- `Preferred` or `Required` mounts mix (`conf.mix = true`). It puts a `MixSendProcessor`
  first in the send chain (`messaging/delivery_service/send_service/`).
- A mixed send is a lightpush request wrapped in a Sphinx packet. It goes over a path of
  three mix hops (`PathLength` 3), and the last node is the lightpush exit
  (`exit_is_dest`), which publishes the message into relay. Each hop adds an exponential
  delay, mean 50 ms. The exit's reply comes back over single-use reply blocks (SURBs).
  The node picks hops and the exit from its **mix pool**: the peers it knows a mix key
  for. A path needs four of them (`MinMixPoolSize`).
- `Preferred` hands a send to the plain path (relay, then lightpush) at once if mix can't
  attempt it. That happens when the pool is short, the node's own hop does not encode, or
  no exit serves the shard. It also falls back after a one-minute mix window with no
  answer. `Required` never falls back: it holds the send for two more passes, then fails
  it. Under `Required` the node also reports `Disconnected` until a mix exit is ready
  (`requireMixReady`).
- A mixed send skips the plain path's store confirmation. That confirmation would ask a
  store node for the message's hash from this node's own address. INFO log lines withhold
  the hash (`msgHash=withheld`).
- What mix is **not**: only lightpush goes over it (`mixify`). Store queries, filter
  subscriptions and delivery's own backfill do not. Delivery mounts mix with **no cover
  traffic and no spam protection** (`MixProtocol.init` gets only a delay strategy). The
  CHANGELOG calls it what it is: sender anonymity.

Both fleets advertise `mix` (`fleets.logos.co`). The `logos.dev` preset ships the six
fleet nodes as mix bootstrap nodes with their mix keys (`networks_config.nim`
`LogosDevConf`). They match the fleet table's `mix_pub_key`s.

## Runs

The host is `bugger`, behind a home NAT. The runner was built from main at `e7058c2` with
delivery v0.3.0. Every run used `logos.dev`, and all 12 fleet nodes answered on :30303
that day. The harness was `two-instance-proof.sh`'s shape: two offscreen runners, A the
founder with auto-admit, B the joiner. Convergence is both at `members=2`. Each mix level
was given through `MUSTER_DELIVERY_CONFIG`, a fleet config with
`messagingOverrides.anonymityLevel` set. No code change was needed for that, because
`node_config.nim` passes `messagingOverrides` through. The scratch harness kept both logs
and timed each milestone from B's launch.

| level | runs | converged | B at `members=2` (s from B's launch) |
|---|---|---|---|
| None (baseline) | 4 + `two-instance-proof.sh` | 5/5 | 10.2, 10.2, 10.3, 10.7 (proof: ~11) |
| Preferred | 4 | 4/4 | 10.8, 11.3, 12.3, 17.4 |
| Required | 3 | 3/3 | 11.8, 14.4, 38.0 |

`card-self-test.sh` was green on the baseline.

**Every send went over mix.** The Preferred and Required runs logged no plain-path send
(no store-validated `Message successfully sent`) and no `Mix cannot carry messages`
fallback. 101 sends ended `Message successfully sent over mix`, and none ended `Failed to
send message`. A few were still retrying when a run was stopped. B's side of one
Preferred send, from the runner's log:

```
MUSTER-LP createNode config={"mode":"Core","preset":"logos.dev","messagingOverrides":{"anonymityLevel":"Preferred","quic-support":false,"log-level":"INFO"}}
INF Mounting mix protocol                         topics="waku node"
INF Using mix bootstrap nodes                     topics="waku mix" entries=1 poolSize=6
INF Mix self hop set                              topics="waku node" hop=/ip4/<public-ip>/tcp/38639 before=/ip4/0.0.0.0/tcp/0
DBG Trying message delivery via Mix               requestId=23d4fbde6b1048f80ec5 msgHash=0xf534…8b95
DBG Destination data                              destination=MixDestination[MixNode](16Uiu2HAm8Yok…kGyuEP)
DBG Selected mix node:                            indexInPath=0 peerId=16U*VpJprH
DBG Selected mix node:                            indexInPath=1 peerId=16U*TwqBiH
DBG Message propagated via Mix                    requestId=23d4fbde6b1048f80ec5
INF Message successfully propagated               requestId=23d4fbde6b1048f80ec5 msgHash=withheld
INF Message successfully sent over mix            requestId=23d4fbde6b1048f80ec5
```

The node found its public address for its own hop by NAT discovery. A node whose hop
cannot be encoded reports `This node's announced address is not one mix can route
replies to` and does not mix. That never happened here.

**Latency.** On the plain path, `Send initiated` to `Message successfully propagated` is
0.00 s (n=56): relay accepts the publish locally. Over mix it is the round trip to the
exit's reply:

| level | n | p50 | p90 | max |
|---|---|---|---|---|
| Preferred | 58 | 1.09 s | 6.17 s | 8.19 s |
| Required | 43 | 0.94 s | 7.06 s | 32.6 s |

Convergence moved much less than the per-send numbers, because the handshake is paced by
B's start and its 5 s re-announce. Most runs stayed within a second or two of the
baseline.

**The tail is dead hops.** Mix gives up on an attempt after 5 s (`Mix lightpush timed
out … timeout=5s`) and retries it. Across the runs, 12 of 74 Preferred attempts and 48
of 98 Required attempts timed out. A node outside the fleet was on the forward or the
reply path of 50 of the 60 timed-out attempts, against 35 of the 84 that succeeded. (A
timeout is matched to the attempt 5 s before it.) Those nodes came from two places:

- **Mix nodes from earlier runs.** Every muster instance with mix on is itself a mix
  node, and it advertises itself. Peers `…HgcJLC` and `…n4ubFF` in run Required-2's paths
  were the A and B of run Preferred-2, killed a few minutes earlier. They were still in
  the pool. That run's B needed 32 attempts for 11 sends and reached `members=2` at 38 s.
  Each instance also uses the other one on the same host as a hop: A was a hop in B's
  paths.
- **Someone else's node.** `…6PpG1L` (51.198.80.6) was in every run's pool, as a hop
  and as an exit. Sends through it often succeeded, and many timeouts went through it.

So a small network whose clients come and go fills its mix pool with stale or unreliable
hops. Every one a send picks costs it 5 s. Repeated self-test runs make this worse, for the runs that
follow and for everyone else on `logos.dev`. This is the main reason the setting stays
off by default.

**More messages, same result.** `split-self-test.sh` with `MUSTER_MIX=preferred` went
final on both instances in ~49 s. The labbook's baseline for it is 36–41 s. A split is a
propose, two agreements, a payment report and a confirmation, all sent over mix. A's 13
mixed sends took 22 timed-out attempts; the pool had grown stale with the instances of the
runs before it. Its slowest send took 41 s. None fell back and none failed.

**Locally, no mix.** `MUSTER_FLEET=local` runs two nodes and no fleet, so no mix
bootstrap nodes. Each node mounts mix with a pool of 0 or 1, below the four a path needs:

- With `MUSTER_MIX=preferred`, every send took the plain path (`Mix cannot carry
  messages, sending them over the plain path instead … reason="mix not mounted or pool
  below: 4"`), and the instances converged at 12.3 s. The row said `warn: 0 of 4 mix
  nodes known: sends go over the plain path until there are 4`.
- With `MUSTER_MIX=required`, every send failed (`Failed to send message … error="mix
  not mounted or pool below: 4"`, 21 on A), and the instances never converged. The row
  said `warn: 1 of 4 mix nodes known: sends wait for 4, then fail`.

So the local network checks the code, never the mixnet.

**`logos.test` was not tried.** A delivery v0.3 node there sends nothing without an active
RLN membership (exo-eb6.3), so mixed sends there have not been tried. RLN proofs are made
by the client since v0.39, so a mixed send should carry one, but that is unverified.

## What mix hides for a muster room, and what it does not

Hidden, with `mix` on and the pool healthy:

- **Who published a room message.** Without mix, a muster node (mode Core) publishes
  straight into the relay mesh. Its first peers are the fleet nodes, which also run the
  store, so they receive each message from the publisher's peer id and IP. With mix, a
  message enters relay at the exit. The exit sees the message but not who sent it. The
  first hop sees the sender's address but not the message, which is a Sphinx packet. The
  middle hop sees neither.
- **The hash of a sent message, toward store nodes.** A mixed send skips the plain path's
  store confirmation, which would ask for the hash from the sender's own address.

Not hidden, mix or no mix:

- **Who reads a room.** muster receives by store query. It pages each topic's history,
  then asks the topic's window every 15 s (`store_catchup.nim`). Each query names the
  content topic and leaves from the reader's own node, so the store node sees which
  rooms a node reads, and when. Delivery's own backfill does the same. The runs show both
  going straight to fleet store peers:
  `MUSTER-LP storeQuery /muster/1/…/proto windowed peer=/dns4/delivery-01…` and `recv
  backfill … contentTopic=/muster/1/…/proto`. The inbox topic is read the same way, so
  the store node can tie a node to its inbox. FS-9's conversation graph rests on these
  reads, so mix closes only the publish half of it.
- **What the message says about the room.** The store and relay still see each published
  message's content topic, timing, size and frame kind (FS-9). Mix removes the publisher,
  not the message.
- **The fleet operator, on `logos.dev` today.** The pool is the six fleet nodes plus the
  few other mix nodes that come and go. The operator who runs the six also runs the store
  nodes. In these runs, 101 of 172 mix attempts (59%) had every hop and the exit on a
  fleet node. The rest went through muster's own test instances or the one other node.
  A path run entirely by that one operator hides nothing from them. Sender anonymity
  here holds against an observer who sees one hop or the store, not against the fleet
  operator. It grows as independent mix nodes join.
- **Timing, against a global observer.** There is no cover traffic and the per-hop delay
  is short (mean 50 ms). A message's appearance at the exit can be matched to a packet
  leaving the sender a moment before.
- **The local log.** Delivery withholds the hash at INFO. At v0.3.0, though, the node logs
  at DEBUG whatever level it is given (exo-9eed), so the runner's own log names every
  mixed message's hash beside its request id. That matters once a log is shared, as in a
  bug report.

## What muster ships (exo-dcc.4)

- **`mix` setting:** `off` | `preferred` | `required`, off by default.
  - Set it with `set_setting("mix", …)`, or in Settings under "Mixnet for sends".
  - `MUSTER_MIX` sets it for runners and self-tests; a saved choice wins.
  - It applies the next time Muster starts: the module boots one delivery node per run (exo-dcc.12), and a second createNode was always refused.
  - `node_config.nim` writes `anonymityLevel` inside `messagingOverrides` beside a preset,
    or at the top of a flat config. With the setting off, `createNode` is unchanged.
  - A delivery config that names its own level, or sets `mix: false`, wins. `settings()`
    reports `mixAsked`, the level the next node is actually asked for.
  - Held by `delivery_node_config_test` §5–9.
- **Mix status row** (`mix_status.nim`), held by `mix_status_test`:
  - It reads what delivery reports: the level `createNode` was given, `getNodeInfo
    MyMixPubKey` (empty when mix is not mounted), the `mix_pool_size` gauge from
    `getNodeInfo Metrics`, and `getConnectionStatus`.
  - Levels: ok when the pool is at least four; warn when it is short, or under Required
    while no exit is ready; down when mix is not mounted; unknown when a reply is unread.
  - Every row carries the sends-only note.
  - `connectivity()` includes the row while sends are asked to ride mix, and Settings
    shows it.
  - Live, with `MUSTER_MIX=preferred` on `logos.dev`, `createNode` got
    `"messagingOverrides":{…,"anonymityLevel":"Preferred"}` from the setting alone. The
    row read: `{"key":"mix","name":"Mixnet","level":"ok","detail":"sends go through the
    mixnet (6 mix nodes known); a send mix cannot carry goes over the plain
    path","covers":"sends","note":"Mix carries this node's sends only. …"}`. It rose to
    7 when the other instance joined the pool.
  - `two-instance-proof.sh` and `card-self-test.sh` are green with mix off, Preferred
    and (the proof) Required. `MUSTER_MIX` reaches them through the environment.
- **Off by default**, for four reasons:
  - The send tail: stale hops cost 5 s each, and Required stretched one handshake to
    38 s.
  - Preferred falls back to the plain path without saying so per message. Only the log
    and the status row tell.
  - `logos.test` is untried.
  - Each instance becomes a mix node that relays for others, and leaves a stale hop behind
    when it exits.
- **No new claims-registry protection.** A "protects" claim needs a test that proves the
  property. The tests here prove that muster asks delivery for mix and reads its state
  back. They do not prove a send is unlinkable, and the setting is off. Claim [4] ("the
  store node still sees the conversation graph") moves from `specified` to `partial`. Its
  fix says what the partial covers: sends, opt-in. The reads that carry the graph have no
  mix path.

## What the campaign may say

> Muster can send a room's messages through the Logos mixnet. It is an opt-in setting,
> built on Logos Delivery 0.3's sender anonymity. It hides which participant sent a
> message, not who reads a room: reading still asks a store node for the room directly.

Not to be said:

- "mixnet integrated", without that qualifier;
- that Muster hides the conversation graph or is metadata-private;
- that it is on by default;
- that it protects against the network's operator. On `logos.dev` most mix nodes are the
  same operator's as the store nodes.

## Reproduce

```bash
make build
scripts/two-instance-proof.sh                      # baseline, logos.dev
MUSTER_MIX=preferred scripts/two-instance-proof.sh # the same over the mixnet (the module reads MUSTER_MIX)
MUSTER_MIX=required  scripts/two-instance-proof.sh
MUSTER_MIX=preferred KEEP_LOGS=1 SPLIT_ANVIL_PORT=<free port> \
  nix shell nixpkgs#foundry --command scripts/split-self-test.sh
# in a run's logs (the split test's KEEP_LOGS dir, or the proof's on FAIL):
grep -aE 'sent over mix|Mix cannot carry|Mix lightpush timed out|Failed to send' <dir>/{A,B}.log
grep -a 'MUSTER-LP connectivity' <dir>/A.log | tail -1   # the mix row
```

Run them sparingly. Each run leaves two dead mix nodes in `logos.dev`'s pool for a while,
and the runs after it pay 5 s for every send that picks one.

## Sources

- logos-delivery `ca28145`, which is delivery_module v0.3.0's pin:
  - `logos_delivery/messaging/delivery_service/send_service/{mix_processor,send_service}.nim`
  - `logos_delivery/messaging/messaging_client.nim` (`requireMixReady`)
  - `logos_delivery/waku/waku_mix/protocol.nim` (`MinMixPoolSize`, `selfHopUsable`, the
    delay strategy)
  - `logos_delivery/waku/api/publish.nim` (`mixReady`, `selectMixLightpushPeer`)
  - `logos_delivery/api/conf/messaging_conf.nim`, and `CHANGELOG.md` v0.39.0
- nim-libp2p-mix `39d2ac7`: `libp2p_mix/mix_metrics.nim` (`mix_pool_size`).
- delivery_module v0.3.0: `delivery_module.lidl` (`createNode`, `connectionStateChanged`)
  and `docs/pages/networks.md` ("Mix routing: on" for both presets).
- The fleet table: <https://fleets.logos.co/data.json>, which lists `mix` and `mix_pub_key`
  per node.
