## Safe driver conformance (invariant 6; secp256k1-linked — see tests/README.md).
##
## The real Safe driver must be conformant: a well-formed, stable describe(), a
## TOTAL verifyContribution (it survives malformed 65-byte signatures — the exact
## recid-abort regression — returning false, never aborting), and descriptor-driven
## core routing. This is the driver-features gate the working agreement names.

import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/conformance
import ../src/crypto/secp256k1

let safeDrv = newSafeDriver(chainId = 31337, safe = default(Address),
                            owners = @[default(Address)], threshold = 2)

# ECDSA-specific hostile contributions: well-formed 65-byte length but every
# out-of-range v byte (the abort window {4..26} ∪ {31..255}), with non-zero r/s.
var hostile: seq[Contribution]
for v in [4'u8, 17, 26, 31, 128, 200, 255]:
  var s = newSeq[byte](65)
  for i in 0 ..< 64: s[i] = byte((i * 7 + 3) and 0xFF)
  s[64] = v
  hostile.add Contribution(bytes: s)

let fails = checkConformance(safeDrv, hostile)
for f in fails: echo "  - ", f
doAssert fails.len == 0, "Safe driver must be conformant"
echo "conformance: Safe driver conformant (verifyContribution total on malformed sigs)"
