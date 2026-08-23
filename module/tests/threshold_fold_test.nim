## The multi-party fold, run with a NON-Safe driver — the proof that the fold is
## driver-generic (not just typed that way). A threshold driver (Ed25519 k-of-n)
## folds the same intent lifecycle to `executable`: k distinct roster endorsements
## complete it, a non-member's endorsement never counts. Same reduceIntents, same
## reduce(log), no Safe, no secp. Needs libsodium (Ed25519). See tests/README.md.

import std/[strutils, tables]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/threshold
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/intents

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(sig: Ed25519Sig): string =
  const d = "0123456789abcdef"
  for b in sig: (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])

# A 3-member roster, threshold 2. Members A/B are in it; Mallory is not.
let a = encFromSeed(seed(1))
let b = encFromSeed(seed(2))
let c = encFromSeed(seed(3))
let mal = encFromSeed(seed(9))
let drv = newThresholdDriver(@[a.identity().ed, b.identity().ed, c.identity().ed], k = 2)

const effectJson = """{"to":"0x1111111111111111111111111111111111111111","value":1000,"nonce":0}"""
let id = intentIdFor(effectJson)
# What roster members sign: the intent's materialization (base dCBOR — this driver
# does not override canonicalize), exactly what reduceIntents will verify against.
let m = canonicalize(drv, effectFromJson(effectJson))
proc endorse(k: EncKeys): string = hex(edSign(k, m.bytes))

# Propose, then one endorsement → collecting (1 of 2).
var events = @[proposeEvent(id, effectJson), contributeEvent(id, "A", endorse(a))]
doAssert intentState(events, drv, id) == "collecting",
         "one roster endorsement -> collecting"
echo "1. propose + one endorsement -> collecting OK"

# A second distinct endorsement → executable (threshold met), through the SAME
# generic reduceIntents — no Safe, no secp.
events.add contributeEvent(id, "B", endorse(b))
doAssert intentState(events, drv, id) == "executable",
         "two distinct roster endorsements -> executable"
echo "2. two endorsements -> executable (generic fold, non-Safe driver) OK"

# A non-roster endorsement never counts toward the threshold.
var ev2 = @[proposeEvent("2", effectJson),
            contributeEvent("2", "A", endorse(a)),
            contributeEvent("2", "mallory", endorse(mal))]
doAssert intentState(ev2, drv, "2") != "executable",
         "a non-member endorsement must not reach the threshold"
echo "3. non-member endorsement refused OK"

echo "threshold_fold_test: all OK"
