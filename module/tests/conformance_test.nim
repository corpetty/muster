## The driver conformance suite, run against both drivers that exist — the stub
## and the Safe driver. This is the "good standard for how drivers are created":
## a new driver passes this before it ships, and the SAME checks grade every
## driver, so a chain-specific driver is a complete unit behind one interface.
## Needs libsecp256k1 (the Safe driver). See tests/README.md.

import std/[strutils, json]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/threshold
import ../src/drivers/frost
import ../src/drivers/registry
import ../src/drivers/conformance
import ../src/crypto/secp256k1
import ../src/crypto/curve25519

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

# ── 3. the registry builds conforming drivers (selection by kind + config) ─────
block:
  let stub = newDriver("stub", %*{"rounds": 1, "threshold": 2})
  let e = Effect(schemaId: "x", fields: @[("a", cbUint(1'u64))])
  let t = Effect(schemaId: "x", fields: @[("a", cbUint(2'u64))])
  doAssert checkConformance(stub, e, t, Contribution(bytes: @[1'u8])).allPass(),
           "registry stub must conform"
  let safe = newDriver("safe", %*{"chainId": 31337,
    "safe": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    "owners": ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"], "threshold": 1})
  doAssert safe.describe().serializationDomain == "eip712.safe.v1.4.1",
           "registry selected the Safe driver by kind"
  var unknownRejected = false
  try: discard newDriver("nope", %*{})
  except RegistryError: unknownRejected = true
  doAssert unknownRejected, "an unknown driver kind is refused"
  echo "3. registry builds conforming drivers, refuses unknown kinds OK"

# ── 4. a threshold (Ed25519 k-of-n) driver conforms — a driver unlike Safe ─────
block:
  proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let member = encFromSeed(seed(5))
  let drv = newThresholdDriver(@[member.identity().ed], k = 1)
  let e = Effect(schemaId: "muster.effect.transfer.v1",
                 fields: @[("to", cbText("0xabc")), ("value", cbUint(5'u64))])
  let t = Effect(schemaId: "muster.effect.transfer.v1",
                 fields: @[("to", cbText("0xabc")), ("value", cbUint(6'u64))])
  let sig = edSign(member, canonicalize(drv, e).bytes)   # a roster member's endorsement
  var cb: seq[byte]
  for b in sig: cb.add b
  let r = checkConformance(drv, e, t, Contribution(bytes: cb))
  doAssert r.allPass(), "threshold driver must conform: failed " & $r.failed()
  echo "4. threshold driver conforms (", r.checks.len, " checks) OK — a driver unlike Safe"

# ── 5. a 2-round FROST-style driver conforms — the first driver with rounds > 1 ──
# Same Ed25519-roster shape as the threshold driver, but describe().rounds = 2, so
# the conformance convergence check drives the core through TWO collection passes
# (it submits the sample k*rounds times). This is the multi-round core path that no
# real driver exercised before.
block:
  proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let member = encFromSeed(seed(7))
  let drv = newFrostDriver(@[member.identity().ed], k = 1)
  doAssert drv.describe().rounds == 2, "the FROST driver must declare two rounds"
  let e = Effect(schemaId: "muster.effect.transfer.v1",
                 fields: @[("to", cbText("0xdef")), ("value", cbUint(7'u64))])
  let t = Effect(schemaId: "muster.effect.transfer.v1",
                 fields: @[("to", cbText("0xdef")), ("value", cbUint(8'u64))])
  let sig = edSign(member, canonicalize(drv, e).bytes)   # a roster member's per-round contribution
  var cb: seq[byte]
  for b in sig: cb.add b
  let r = checkConformance(drv, e, t, Contribution(bytes: cb))
  doAssert r.allPass(), "FROST driver must conform: failed " & $r.failed()
  echo "5. FROST driver conforms (", r.checks.len, " checks) OK — the first rounds>1 driver"

# ── 6. the registry builds the FROST driver by kind ───────────────────────────
block:
  proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let member = encFromSeed(seed(9))
  var rosterHex = "0x"
  const hexd = "0123456789abcdef"
  for b in member.identity().ed: (rosterHex.add hexd[int(b shr 4)]; rosterHex.add hexd[int(b and 0x0F)])
  let frost = newDriver("frost", %*{"roster": [rosterHex], "k": 1})
  doAssert frost.describe().serializationDomain == "muster.frost.v1",
           "registry selected the FROST driver by kind"
  doAssert frost.describe().rounds == 2, "registry FROST driver keeps its two rounds"
  echo "6. registry builds the FROST driver by kind OK"

echo "conformance_test: all OK"
