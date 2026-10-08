# The store's 24 h rule, and the deal a relaunch lost (exo-dcc.12, 2026-10-08)

Seen on display in Basecamp 0.3.2 on 2026-10-07: a one-member room came back after a
relaunch (`rooms restored=1`), but Home read "no proposals yet" and the room history was
empty. The first session's log held 174 store refusals, `BAD_REQUEST: time range exceeds
24h`. The two looked like one bug: muster's catch-up reads a topic whole, so it seemed to
ask for more than a day of history and be refused. They are two bugs, and neither is in
muster's catch-up.

## The 174 refusals are delivery's own catch-up, not muster's

Count them by logger:

```
grep "time range exceeds" bc1.log | grep -o 'topics="[^"]*"' | sort | uniq -c
     29 topics="recv backfill"
    145 topics="waku store client"
```

145 is 29 × 5: each `recv backfill` pass tries five store peers ("Store query failed,
trying next peer") before it gives up on a topic ("Store catch-up query failed, the topic
retries next pass"). `recv backfill` is the delivery node's **own** startup catch-up
(logos-delivery#4227, "Store catch-up across process restarts"). Every one of muster's
`storeQuery` calls in the same session was answered `statusCode 200`.

**The rule.** logos-delivery#4349 (2026-09-29) makes a store node refuse a query that
names **both** ends of a range more than 24 h apart (`waku_store/common.nim`, `validate`).
Either end alone is never checked. The `logos.dev` fleet runs it since its redeploy of
2026-10-02.

**Why delivery v0.3.0 trips it.** The node in the log is `nwaku v0.39.0-gca2814`, which is
delivery_module 0.3.0. Its catch-up, on a first launch with no saved hint, asks for
`[start − 24 h, now)`: a few milliseconds over 24 h, so it is refused on every pass for as
long as the node runs. After a relaunch it asks from the node's last moment online, minus
40 s, so a node that was down for more than a day is refused the same way. #4349 also made
the catch-up walk that range in windows of at most 24 h. That shipped in logos-delivery
v0.39.1, which is delivery_module **0.3.2**, the version Basecamp 0.3.2's own catalog
serves. The Basecamp run installed 0.3.0 from `infra/basecamp/catalog-0.3.1.tsv`, and
muster's runner pinned 0.3.0 too.

**Why muster's queries are never refused.** The history read names no time at all, and
the sliding window names only `timeStart`. So a room of any age is read from its first
message. `store_catchup_test` §12 holds this with a room three days old, and with a
window lookback past 24 h. Live, a throwaway identity joined a dead split self-test room
on `logos.dev` (`/muster/1/split-1791316516/proto`, first frame 2026-10-06 19:55 UTC).
At 41.7 h old, and again at 46 h, muster's history read got every frame back: 132, 215,
246, 370, 373, 437, 512, 530 and 633 bytes, the same set the original session saw. So
`logos.dev` keeps a room for at least two days, and its age is no bar to a relaunch.

**Fix.** muster pins delivery_module v0.3.2 (`module/flake.nix`, `ui/flake.nix`).
`scripts/relaunch-self-test.sh` now runs the node at DEBUG, gives each launch 15 s for its
catch-up, and fails on any `time range exceeds 24h`.

| runner | fleet | relaunch-self-test |
|---|---|---|
| main, delivery 0.3.0 (`nwaku v0.39.0-gca2814`) | logos.dev | **red**: 18 refusals on the first launch (3 `recv backfill`, 15 `waku store client`), 0 on the relaunch; all 8 muster store queries answered 200 |
| this branch, delivery 0.3.2 (`v0.39.0-g3a478e`, the v0.39.1 line) | logos.dev | green, 0 refusals |
| the same | local (no store node) | green |

The 0.3.2 node logs at DEBUG under `MUSTER_DELIVERY_LOG=DEBUG` (some 400 DBG lines in 45 s),
so the green is not a log level hiding the refusals. With 0.3.2, `scripts/ui-parity.sh` went 10
of 10 green on `logos.dev` and on `MUSTER_FLEET=local`. The split test needs `anvil`, so
it ran under `nix shell nixpkgs#foundry`.

## The lost proposal is epoch 0's key, not the store

On every relaunch, muster's own whole-topic read got every frame back from the store. In
`bc2.log`, the first relaunch, it read 2 × 113, 4 × 209, 2 × 512 and 2 × 530 bytes: the
two proposals of the first session. The "17- and 33-byte frames only" were delivery's own
`source=history` replay. That replay starts at the node's last moment online, so it held
only the last few beacon requests (17 bytes: tag `0x05` and a 16-byte nonce) and a beacon
(33 bytes: tag `0x04` and a 32-byte join key).

The room still read `msgs=0`. Every frame was sealed under epoch 0, and on main
`newEpochCrypto` draws epoch 0's key at random on each launch. No grant carries it, so the
restarted founder could open none of it. In `bc3.log` the count rose to 3 with new
messages, and in `bc4.log` it fell back to 1: each launch lost the one before. This is
exo-6dc.1, and **PR #220** fixes it by deriving epoch 0 from the keystore and the room. As
of 2026-10-08 that PR is open and conflicts with main. Its
`scripts/founding-relaunch-self-test.sh`, run against a runner built from main, fails
here outside Basecamp too. Its first launch shows the proposal card after ~10 s. After
the relaunch, the proposal's frames (116, 187, 226, 512 and 530 bytes) arrive, but after
120 s the founder still reads `members=1 msgs=0`.

`relaunch-self-test.sh` never saw this, because it checks only that the room is
re-entered (`rooms restored=1`), not what is in it. The "Ask to join this room" button is
not a symptom: the room panel always shows it. The 223-byte frames that follow a relaunch
are the UI's own join request, re-sent every few seconds.

## Still open

- **CLAUDE.md** still says muster pins delivery v0.3.0, in its Testnet v0.3 paragraph.
- **The Basecamp harness** installs delivery 0.3.0 from `infra/basecamp/catalog-0.3.1.tsv`.
  A run on Basecamp 0.3.2 wants that catalog's 0.3.2.
- **PR #220 (exo-6dc.1)** has to land. Until it does, a founder who relaunches before
  admitting anyone loses everything said and proposed in the room.
- **A room lives only in the store.** muster keeps no local copy of a room's log
  (`joined_rooms.nim`: "rebuilt from the store and the keystore"). The fleet's
  store-retention policy is therefore the room's lifetime. The infra role's default is
  `size:1GB`, a capacity policy, so a busy fleet can age out a slow deal's history.
  Invariant 4 only says the state can be rebuilt from log + keys. Today nothing on the
  member's own machine holds the log.
