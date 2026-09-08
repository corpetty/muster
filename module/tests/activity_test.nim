## The activity fold (reduceActivity): the room's coordination history as reduce(log).
## A narrative of every state transition — proposed, each approval (running count),
## threshold reached, submitted, settled — in canonical order, from the same events
## the cards fold from. Uses the threshold (Ed25519) driver so it runs without secp.
import std/[strutils, sequtils]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/threshold
import ../src/coordination/intents
import ../src/crypto/curve25519
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc sigHex(s: Ed25519Sig): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in s: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# a 2-of-2 threshold room so we see the count climb 1→2 and then "ready"
let m1 = encFromSeed(seed(1))
let m2 = encFromSeed(seed(2))
let drv = newThresholdDriver(@[m1.identity().ed, m2.identity().ed], 2)
let fold: DriverFor = proc(k: string): Driver = drv

let effect = """{"to":"0xabc","value":7,"nonce":0}"""
let id = intentIdFor(effect, "threshold")
let mat = canonicalize(drv, effectFromJson(effect))
let who1 = contributorOf(drv, effect, sigHex(edSign(m1, mat.bytes)))
let who2 = contributorOf(drv, effect, sigHex(edSign(m2, mat.bytes)))

var ev = @[policyDeclEvent(id, "threshold"), proposeEvent(id, effect)]

# ── 1. after only a propose: one entry, and it is the proposal ────────────────
block:
  let a = reduceActivity(ev, fold)
  doAssert a.len == 1, "propose alone yields one entry, got " & $a.len
  doAssert a[0].kind == "propose"
  doAssert "a payment: 7" in a[0].title, "the effect is summarized: " & a[0].title
  doAssert not ("ready" in a.mapIt(it.kind)), "not ready on a bare propose"
  echo "1. propose → one 'propose' entry OK"

# ── 2. one approval: count reads 1 of 2, still not ready ──────────────────────
ev.add contributeEvent(id, who1, sigHex(edSign(m1, mat.bytes)), 1)
block:
  let a = reduceActivity(ev, fold)
  let kinds = a.mapIt(it.kind)
  doAssert "approve" in kinds, "an approval appears"
  let ap = a.filterIt(it.kind == "approve")[0]
  doAssert "1 of 2" in ap.detail, "running count 1 of 2: " & ap.detail
  doAssert not ("ready" in kinds), "one of two is not ready yet"
  echo "2. first approval → '1 of 2 needed', not ready OK"

# ── 3. second approval: 2 of 2 AND a 'ready' line appears ─────────────────────
ev.add contributeEvent(id, who2, sigHex(edSign(m2, mat.bytes)), 1)
block:
  let a = reduceActivity(ev, fold)
  let kinds = a.mapIt(it.kind)
  doAssert "ready" in kinds, "threshold met → a 'ready' entry: " & $kinds
  let aps = a.filterIt(it.kind == "approve")
  doAssert aps.len == 2, "two distinct approvals, got " & $aps.len
  doAssert "2 of 2" in aps[1].detail, "final approval reads 2 of 2: " & aps[1].detail
  # ready must come AFTER both approvals in the timeline (ordering by seq/order)
  var readyIdx = -1
  var lastApproveIdx = -1
  for i in 0 ..< a.len:
    if a[i].kind == "ready": readyIdx = i
    if a[i].kind == "approve": lastApproveIdx = i
  doAssert readyIdx > lastApproveIdx, "ready is narrated after the last approval"
  echo "3. second approval → '2 of 2' + a 'ready' line, after the approvals OK"

# ── 4. determinism: same events fold the identical timeline (inv 4) ───────────
block:
  let a = reduceActivity(ev, fold)
  let b = reduceActivity(ev, fold)
  doAssert a.len == b.len
  for i in 0 ..< a.len:
    doAssert a[i].kind == b[i].kind and a[i].title == b[i].title, "deterministic"
  # a duplicate contribution folds once — no extra approve line
  var ev2 = ev
  ev2.add contributeEvent(id, who1, sigHex(edSign(m1, mat.bytes)), 1)   # dup of who1
  doAssert reduceActivity(ev2, fold).len == a.len, "a duplicate signature folds once"
  echo "4. deterministic + duplicate folds once OK"

echo "activity_test: all OK"
