## Only a member who endorsed a module action runs it (exo-3b3.18, audit P4-06).
##
## An invoke intent that reached executable runs with the tokens of whoever presses "Run the
## action" (coordinate_execute). runRefusal is the module's gate: a member whose own approval
## the fold counts may run it; anyone else, the proposer who never approved included, is
## refused. Pure fold, in-process: no transport, no host.
## Link flags (curve25519 + dcbor + secp): see tests/README.md.

import std/strutils
import ../src/coordination/intents
import ../src/coordination/invoke_run
import ../src/drivers/invoke
import ../src/drivers/driver
import ../src/intents/materialization
import ../src/crypto/curve25519
import ./probes/attested          # the endorsement as the live path makes it: attested in the room (exo-3b3.9)

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc lowHex(b: openArray[byte]): string = toHex(b)[2 .. ^1]
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

let endorser = encFromSeed(seed(31))
let other = encFromSeed(seed(32))
let roster = @[endorser.identity().ed, other.identity().ed]
let driverFor: DriverFor = proc(kind: string): Driver =
  (if kind == "invoke": Driver(newInvokeDriver(roster, 1)) else: Driver(newStubDriver()))
let drv = newInvokeDriver(roster, 1)

let effectJson = """{"effect":"invoke","module":"delivery_module","method":"send","args":["/room","hello"]}"""
let id = intentIdFor(effectJson, "invoke")
let mat = canonicalize(drv, effectFromJson(effectJson))
let sigHex = toHex(edSign(endorser, mat.bytes))
let who = contributorOf(drv, effectJson, sigHex)
doAssert who.len > 0
var events = @[policyDeclEvent(id, "invoke"), proposeEvent(id, effectJson)]

proc names(e: EncKeys): seq[string] = @["ed:" & lowHex(e.identity().ed)]

doAssert runRefusal(events, driverFor, id, endorser.identity(), names(endorser)).len > 0,
  "an intent no one endorsed is run by no one"
events.add contributeEvent(id, who, sigHex)
events = withAttestations(events, driverFor, id, [endorser])
doAssert intentState(events, driverFor, id) == "executable"
doAssert runRefusal(events, driverFor, id, endorser.identity(), names(endorser)) == "",
  "the member who endorsed it may run it"
let r = runRefusal(events, driverFor, id, other.identity(), names(other))
doAssert r.len > 0 and "endorse" in r, "a member who did not endorse it is refused: " & r
echo "1. only an endorser runs an executable action OK"

echo "invoke_run_gate_test: all OK"
