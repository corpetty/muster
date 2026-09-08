## The submit → final fold: a settled intent reaches `final` ("paid" in the UI), not
## just `submitted`. Regression for the "never gets to paid" bug — coordinate_submit
## now publishes a finalEvent on a real on-chain success, and the fold applies it.
import std/strutils
import ../src/dcbor/dcbor
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
let m = encFromSeed(seed(1))
let drv = newThresholdDriver(@[m.identity().ed], 1)
let fold: DriverFor = proc(k: string): Driver = drv
let effect = """{"to":"0xabc","value":1,"nonce":0}"""
let id = intentIdFor(effect, "threshold")
let mat = canonicalize(drv, effectFromJson(effect))
let who = contributorOf(drv, effect, sigHex(edSign(m, mat.bytes)))
var ev = @[policyDeclEvent(id, "threshold"), proposeEvent(id, effect),
           contributeEvent(id, who, sigHex(edSign(m, mat.bytes)), 1)]
doAssert intentState(ev, fold, id) == "executable"
ev.add submitEvent(id)
doAssert intentState(ev, fold, id) == "submitted", "submit event → submitted"
ev.add finalEvent(id)
doAssert intentState(ev, fold, id) == "final", "final event → final (renders 'paid')"
echo "final_fold_test: executable → submitted → final OK"
