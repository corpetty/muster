## FROST end to end through the ROOM fold (reduceIntents) — the path the single-round
## per-member dedup used to stall. Two rounds, k = 2 each: two distinct members sign in
## round 1 (the fold advances to round 2 but is NOT executable), then two distinct
## members sign in round 2 (the fold reaches executable). This is what makes the
## 2-round driver actually usable in a room, not just in the core Collection.
##
## Note on semantics: in the live flow, coordinate_contribute tags each contribution
## with the intent's CURRENT round, and round 1 is deduped per member — so round 2 is
## only reachable once k DISTINCT members have signed round 1. The fold enforces "at
## most one contribution per (member, round)", so completing a k-of-n / r-round intent
## needs k*r signer-contributions with at most r from any one member (a single member
## can never complete it). This test drives events the way the live flow produces them.

import std/[strutils, tables]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/frost
import ../src/coordination/intents
import ../src/crypto/curve25519

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc sigHex(sig: Ed25519Sig): string =
  const hexd = "0123456789abcdef"
  result = "0x"
  for b in sig: (result.add hexd[int(b shr 4)]; result.add hexd[int(b and 0x0F)])

let m1 = encFromSeed(seed(1))
let m2 = encFromSeed(seed(2))
let m3 = encFromSeed(seed(3))
let drv = newFrostDriver(@[m1.identity().ed, m2.identity().ed, m3.identity().ed], k = 2)
let foldDrv: DriverFor = proc(kind: string): Driver = drv

let effectJson = """{"effect":"transfer","to":"0x1111111111111111111111111111111111111111","value":1000,"nonce":0}"""
let id = intentIdFor(effectJson, "frost")
let mat = canonicalize(drv, effectFromJson(effectJson))
let s1 = sigHex(edSign(m1, mat.bytes))
let s2 = sigHex(edSign(m2, mat.bytes))
let w1 = contributorOf(drv, effectJson, s1)   # "frost:<m1 pubkey hex>"
let w2 = contributorOf(drv, effectJson, s2)
doAssert w1.len > 0 and w2.len > 0 and w1 != w2, "two distinct roster members"

# propose the intent + declare it runs under the FROST policy.
var events = @[policyDeclEvent(id, "frost"), proposeEvent(id, effectJson)]

# ── round 1 — two distinct members. The core advances to round 2 (from describe()),
#    but the intent is NOT yet executable: the second round is still open.
events.add contributeEvent(id, w1, s1, round = 1)
doAssert intentState(events, foldDrv, id) == "collecting", "one signer in round 1 → collecting"
events.add contributeEvent(id, w2, s2, round = 1)
doAssert intentState(events, foldDrv, id) == "collecting", "round-1 threshold met, but round 2 pending"
doAssert reduceIntents(events, foldDrv)[id].collection.round == 2, "the fold advanced to round 2"
echo "1. round 1 (2 distinct members) → collecting, advanced to round 2 OK"

# ── round 2 — two distinct members → executable.
events.add contributeEvent(id, w1, s1, round = 2)
doAssert intentState(events, foldDrv, id) == "collecting", "one signer in round 2 → still collecting"
events.add contributeEvent(id, w2, s2, round = 2)
doAssert intentState(events, foldDrv, id) == "executable", "round-2 threshold met → executable"
echo "2. round 2 (2 distinct members) → executable OK"

# ── the view exposes round progress so a card can render "round R of N".
block:
  let views = reduceIntentViews(events, foldDrv)
  doAssert views.len == 1
  doAssert views[0].policy == "frost" and views[0].rounds == 2, "view carries the FROST policy + 2 rounds"
echo "3. reduceIntentViews exposes rounds=2 for a FROST intent OK"

# ── a single member cannot complete it — at most one contribution per (member, round),
#    so w1 alone gives 2 of the 4 signer-contributions a k=2 / 2-round intent needs.
block:
  let solo = @[policyDeclEvent("x", "frost"), proposeEvent("x", effectJson),
               contributeEvent("x", w1, s1, round = 1),
               contributeEvent("x", w1, s1, round = 1),   # same (member, round) → folds once
               contributeEvent("x", w1, s1, round = 2)]
  doAssert intentState(solo, foldDrv, "x") != "executable",
           "one member cannot complete a k=2, 2-round FROST intent"
echo "4. a single member cannot complete it (k distinct signers required) OK"

# ── a non-member's signature never counts (invariant 6), same as every driver.
block:
  let outsider = encFromSeed(seed(99))
  let so = sigHex(edSign(outsider, mat.bytes))
  doAssert contributorOf(drv, effectJson, so).len == 0, "a non-member has no contributor id"
echo "5. non-member signature refused OK"

echo "frost_room_test: 2-round FROST converges end to end through the room fold OK"
