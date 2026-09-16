## Keyed coordinate_contribute (exo-45e K5, K2b): a contributor signs with a CHOSEN key
## (Keystore.signWith by ref), so ONE instance holding several owner keys can contribute
## as EACH of them — enough of a k-of-n by itself. The keystore never releases a secret;
## the driver verifies each signature recovers to a configured owner. Links secp + sodium.

import std/strutils
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/crypto/keystore
import ../src/crypto/secp256k1

proc bytesOf(hex: string): seq[byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] in {'x','X'}): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc secret(hex: string): array[32, byte] =
  let b = bytesOf(hex); (for i in 0 ..< 32: result[i] = b[i])
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

# The anvil owner keys (accounts 0 and 1) — their addresses are two of the Safe's owners.
const KEY0 = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # → 0xf39F…2266
const KEY1 = "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"  # → 0x7099…79C8

# One instance that holds BOTH owner keys.
let ks = newInMemoryKeystore(secret(KEY0), seed(1))
let ref1 = ks.addKey(secret(KEY1), seed(2))
let ref0 = refOf(ks.address())

let owner0 = ks.address()
let owner1 = addressOf(secret(KEY1))
let drv = newSafeDriver(chainId = 31337, safe = addressOf(secret(KEY0)),
                        owners = @[owner0, owner1], threshold = 2)
let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
  ("to", cbText("0x1111111111111111111111111111111111111111")),
  ("value", cbUint(1000'u64)), ("nonce", cbUint(0'u64))])
let mat = canonicalize(drv, effect)
var h: array[32, byte]
for i in 0 ..< min(32, mat.bytes.len): h[i] = mat.bytes[i]

# ── 1. both keys are held; each ref is distinct and known ─────────────────────────
block:
  doAssert ks.keyRefs().len == 2 and ref0 in ks.keyRefs() and ref1 in ks.keyRefs()
  doAssert ref0 != ref1
  echo "1. one instance holds both owner keys, selectable by ref OK"

# ── 2. signWith(ref) signs AS that key — each recovers to its own owner ────────────
block:
  let sig0 = ks.signWith(ref0, h)
  let sig1 = ks.signWith(ref1, h)
  doAssert ecrecover(h, sig0) == owner0, "ref0 signs as owner0"
  doAssert ecrecover(h, sig1) == owner1, "ref1 signs as owner1"
  doAssert sig0 != sig1, "different keys, different signatures"
  echo "2. signWith(ref) signs as the chosen key — each recovers to its own owner OK"

# ── 3. the Safe driver accepts each as its owner — one instance meets 2-of-3 ───────
block:
  drv.expectMaterialization(mat)
  let sig0 = ks.signWith(ref0, h)
  let sig1 = ks.signWith(ref1, h)
  doAssert drv.verifyContribution(Contribution(bytes: @(sig0)), 1), "owner0's keyed sig verifies"
  doAssert drv.verifyContribution(Contribution(bytes: @(sig1)), 1), "owner1's keyed sig verifies"
  # both are DISTINCT recognized owners, so a single instance holding two owner keys
  # can complete a 2-of-3 collection by contributing under each ref.
  doAssert ecrecover(h, sig0) != ecrecover(h, sig1)
  echo "3. the Safe driver accepts each keyed contribution as its owner (2-of-3 from one instance) OK"

# ── 4. an unknown ref is refused — never a silent fall-through to another key ──────
block:
  var refused = false
  try: discard ks.signWith("0xnope", h)
  except KeystoreError: refused = true
  doAssert refused, "signWith on an unknown ref refuses (the contribute handler returns unknown-key)"
  echo "4. an unknown key ref is refused OK"

echo "keyed_contribute_test: all OK"
