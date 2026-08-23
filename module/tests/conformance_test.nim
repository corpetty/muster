## The driver conformance suite, run against both drivers that exist — the stub
## and the Safe driver. This is the "good standard for how drivers are created":
## a new driver passes this before it ships, and the SAME checks grade every
## driver, so a chain-specific driver is a complete unit behind one interface.
## Needs libsecp256k1 (the Safe driver). See tests/README.md.

import std/strutils
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/conformance
import ../src/crypto/secp256k1

proc bytesOf(hex: string): seq[byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc toAddr(hex: string): Address =
  let b = bytesOf(hex)
  for i in 0 ..< min(20, b.len): result[i] = b[i]

# ── 1. the stub driver conforms ───────────────────────────────────────────────
block:
  let d = newStubDriver(rounds = 1, threshold = 2, verifyResult = true)
  let effect = Effect(schemaId: "x", fields: @[("a", cbUint(1'u64))])
  let tampered = Effect(schemaId: "x", fields: @[("a", cbUint(2'u64))])
  let r = checkConformance(d, effect, tampered, Contribution(bytes: @[1'u8]))
  doAssert r.allPass(), "stub driver must conform: failed " & $r.failed()
  echo "1. stub driver conforms (", r.checks.len, " checks) OK"

# ── 2. the Safe driver conforms ───────────────────────────────────────────────
# The anvil fixture: chainId 31337, the fixture Safe, owners = anvil accounts 0/1/2.
# The valid contribution is owner-0's real signature over the effect's safeTxHash
# (the same fixture the collect/multiparty tests use).
block:
  let drv = newSafeDriver(chainId = 31337,
    safe = toAddr("0x5FbDB2315678afecb367f032d93F642f64180aa3"),
    owners = @[toAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
               toAddr("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
               toAddr("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")],
    threshold = 1)   # threshold 1 so one fixture signature completes the collection
  let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
    ("to", cbText("0x1111111111111111111111111111111111111111")),
    ("value", cbUint(1000'u64)), ("nonce", cbUint(0'u64))])
  let tampered = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
    ("to", cbText("0x1111111111111111111111111111111111111111")),
    ("value", cbUint(9999'u64)), ("nonce", cbUint(0'u64))])
  const sig0 = "0x00278ad6c27d00993883a10909200661d6559d4eea8ca3c9ee3367e8761ba7056fe11cb9a6e87ede5aef673a0f075b220a3c6d37842743c91d9868d834edffcd1b"
  let r = checkConformance(drv, effect, tampered, Contribution(bytes: bytesOf(sig0)))
  doAssert r.allPass(), "Safe driver must conform: failed " & $r.failed()
  echo "2. Safe driver conforms (", r.checks.len, " checks) OK"

echo "conformance_test: all OK"
