## exo-001: a dev-seeded keystore IS a real anvil Safe owner, so its IN-APP Safe
## signature recovers to that owner — which is what lets an in-app approval settle
## on-chain (the folded signatures are real on-chain owners). Seeds the secp key with
## anvil account 0's private key and checks (1) the address is owner 0, and (2) a
## keystore secp signature over the re-derived safeTxHash is recognised by the Safe
## driver as a configured owner's contribution.
##
## Needs libsecp256k1 (the Safe driver + keystore). See tests/README.md; runs in the
## nix build / CI where the nimble deps are present.

import std/strutils
import ../src/crypto/keystore
import ../src/crypto/secp256k1
import ../src/drivers/safe
import ../src/drivers/driver
import ../src/intents/materialization
import ../src/dcbor/dcbor

proc hexBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc toAddr(hex: string): Address =
  let b = hexBytes(hex)
  for i in 0 ..< min(20, b.len): result[i] = b[i]

# anvil account 0 — the well-known dev key and its address (a MiniSafe owner).
const ANVIL_KEY0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
const OWNER0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
const OWNER1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
const OWNER2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
const SAFE_ADDR = "0x5FbDB2315678afecb367f032d93F642f64180aa3"

# a keystore seeded with the owner key (the shape openFileKeystore takes as secpSeed).
var secret: array[32, byte]
let sb = hexBytes(ANVIL_KEY0)
for i in 0 ..< 32: secret[i] = sb[i]
var encSeed: array[32, byte]
for i in 0 ..< 32: encSeed[i] = byte(i + 1)
let ks = newInMemoryKeystore(secret, encSeed)

doAssert ks.address() == toAddr(OWNER0), "a keystore seeded with anvil key 0 IS Safe owner 0"
echo "1. seeded keystore address == anvil Safe owner 0 OK"

# the room Safe over the anvil owners; the seeded keystore signs the safeTxHash in-app.
let drv = newSafeDriver(chainId = 31337, safe = toAddr(SAFE_ADDR),
  owners = @[toAddr(OWNER0), toAddr(OWNER1), toAddr(OWNER2)], threshold = 2)
let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
  ("to", cbText("0x1111111111111111111111111111111111111111")),
  ("value", cbUint(1000'u64)), ("nonce", cbUint(0'u64))])
let mat = canonicalize(drv, effect)
var h: array[32, byte]
for i in 0 ..< 32: h[i] = mat.bytes[i]         # SafeDriver materialization == the 32-byte safeTxHash
let sig = ks.sign(h)                           # the in-app secp signature
var sigBytes: seq[byte]
for x in sig: sigBytes.add x

drv.expectMaterialization(mat)
doAssert drv.identifyContributor(mat, Contribution(bytes: sigBytes)).len > 0,
         "the in-app Safe signature recovers to a configured owner (owner 0)"
echo "2. the in-app Safe signature recovers to a real owner → an in-app approval can settle on-chain OK"
echo "safe_owner_seed_test: a seeded account signs Safe in-app as a real owner OK"
