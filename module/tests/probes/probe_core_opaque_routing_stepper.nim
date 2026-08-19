## derived-exo-2dc s1/c1: the core's routing is unaffected by what contribution
## bytes contain — it never parses them, only routes opaque blobs to the driver.
##
## Stepper over payload classes (well-formed, garbage, truncated, adversarial)
## crossed with the driver's fixed verify answer and the submit count. With the
## driver's answer held constant (the stub ignores bytes), the core's resulting
## state must equal the well-formed baseline for every payload class — a core
## that peeked at the bytes (e.g. rejected garbage or choked on a CBOR marker)
## would diverge. Emits {"payload_class": "...", "routing_matches_baseline": ...}.

import ../../src/drivers/driver

proc payload(cls: string): seq[byte] =
  case cls
  of "well_formed": @[0x01'u8, 0x02, 0x03, 0x04]
  of "garbage": @[0xFF'u8, 0x00, 0xAB, 0xCD, 0xEF]
  of "truncated": @[]
  of "adversarial": @[0x1F'u8, 0xF9, 0x00, 0x5F]   # CBOR indefinite + float markers
  else: @[]

proc runSeq(cls: string, verifyResult: bool, n: int): (int, int, bool) =
  let drv = newStubDriver(rounds = 2, threshold = 2, verifyResult = verifyResult)
  var col = startCollection(drv)
  for i in 0 ..< n:
    col.submit(drv, Contribution(bytes: payload(cls)))
  (col.round, col.acceptedThisRound, col.complete)

var allMatch = true
for verifyResult in [true, false]:
  for n in 0 .. 4:
    let baseline = runSeq("well_formed", verifyResult, n)
    for cls in ["well_formed", "garbage", "truncated", "adversarial"]:
      let m = runSeq(cls, verifyResult, n) == baseline
      if not m: allMatch = false
      echo "{\"payload_class\": \"", cls, "\", \"routing_matches_baseline\": ",
           (if m: "true" else: "false"), "}"

doAssert allMatch, "core routing depended on contribution byte content"
