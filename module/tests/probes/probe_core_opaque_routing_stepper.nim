## derived-exo-2dc s1/c1: the core's routing is unaffected by what contribution
## bytes contain — it never parses them, only routes opaque blobs to the driver.
##
## STEPPER (exo-dbc): state is the payload class; successors are the other
## classes. Each verdict quantifies over the driver's verify answer and the
## submit count, neither of which the state carries: with the driver's answer
## held fixed (the stub ignores bytes), the core's resulting state must equal the
## well-formed baseline. A core that peeked at the bytes — rejecting garbage,
## choking on a CBOR marker — would diverge.

import ../../src/drivers/driver
import ./oracle_emit

const Classes = ["well_formed", "garbage", "truncated", "adversarial"]

proc payload(cls: string): seq[byte] =
  case cls
  of "well_formed": @[0x01'u8, 0x02, 0x03, 0x04]
  of "garbage": @[0xFF'u8, 0x00, 0xAB, 0xCD, 0xEF]
  of "truncated": @[]
  of "adversarial": @[0x1F'u8, 0xF9, 0x00, 0x5F]   # CBOR indefinite + float markers
  else: raiseAssert "unknown payload class: " & cls

proc runSeq(cls: string, verifyResult: bool, n: int): (int, int, bool) =
  let drv = newStubDriver(rounds = 2, threshold = 2, verifyResult = verifyResult)
  var col = startCollection(drv)
  for i in 0 ..< n:
    col.submit(drv, Contribution(bytes: payload(cls)))
  (col.round, col.acceptedThisRound, col.complete)

proc matchesBaseline(cls: string): bool =
  for verifyResult in [true, false]:
    for n in 0 .. 4:
      if runSeq(cls, verifyResult, n) != runSeq("well_formed", verifyResult, n):
        return false
  true

proc state(cls: string): JsonNode =
  %*{"payload_class": cls, "routing_matches_baseline": matchesBaseline(cls)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "payload_class", "well_formed")
var succ: seq[JsonNode]
for c in Classes:
  if c != here: succ.add state(c)
emitSuccessors(succ)

if arg == nil:
  for c in Classes:
    doAssert matchesBaseline(c), "core routing depended on contribution byte content"
