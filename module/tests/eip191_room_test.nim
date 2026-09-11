## Room-native EIP-191 attestation, folded (P-D6 wiring): the eip191 policy driven
## through the generic reduceIntents path, exactly as the room does it. Two owners
## personal-sign an agreed effect over a SHARED signer set (the Safe owner set — the
## one secp set every instance derives identically), and the fold converges to
## executable. This is what makes "eip191" a real room policy, not just a registered
## driver. Link flags: secp + libsodium (intents pulls curve25519). See tests/README.md.

import std/strutils
import ../src/coordination/intents
import ../src/drivers/driver as drivercore
import ../src/drivers/eip191
import ../src/intents/materialization
import ../src/crypto/secp256k1

proc hex32(s: string): array[32, byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc addrHex(a: Address): string =
  const d = "0123456789abcdef"
  result = "0x"
  for b in a: (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])
proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# Two owners (anvil 0/1) — the SHARED signer set every instance derives from the Safe.
const sk0 = hex32("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
const sk1 = hex32("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
let owner0 = addressOf(sk0)
let owner1 = addressOf(sk1)

# The room's driver for the eip191 policy — signers = the owner set, k = 2. Every
# instance builds THIS identical driver (muster_module's driverForKind "eip191" arm),
# so the fold is convergent.
let foldDrv: DriverFor = proc(kind: string): drivercore.Driver =
  newPersonalSignDriver(signers = @[owner0, owner1], threshold = 2)
let drv = foldDrv("eip191")

const effectJson = """{"effect":"statement","text":"the owners attest: release v0.1"}"""
let id = intentIdFor(effectJson, "eip191")
let mat = canonicalize(drv, effectFromJson(effectJson))

proc sigOver(sk: array[32, byte]): string =
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = mat.bytes[i]
  toHex(signRecoverable(h, sk))

# 1. propose the attestation under the eip191 policy.
var events = @[policyDeclEvent(id, "eip191"), proposeEvent(id, effectJson)]
doAssert intentState(events, foldDrv, id) == "proposed"
doAssert effectJsonOf(events, id) == effectJson
echo "1. eip191 attestation proposed OK"

# 2. owner0 personal-signs the EIP-191 digest — one contribution, still collecting.
let s0 = sigOver(sk0)
let who0 = contributorOf(drv, effectJson, s0)
doAssert who0 == addrHex(owner0), "owner0's personal_sign identifies owner0"
events.add contributeEvent(id, who0, s0)
doAssert intentState(events, foldDrv, id) == "collecting", "1 of 2 — still collecting"
echo "2. owner0 attests -> collecting OK"

# 3. owner1 signs — threshold met, the attestation is executable (a signed group
#    statement; nothing settles on-chain, finImmediate).
let s1 = sigOver(sk1)
let who1 = contributorOf(drv, effectJson, s1)
doAssert who1 == addrHex(owner1) and who1 != who0, "owner1 is a distinct signer"
events.add contributeEvent(id, who1, s1)
doAssert intentState(events, foldDrv, id) == "executable", "2 of 2 — the owners attested"
echo "3. owner1 attests -> executable (the room attested) OK"

# 4. a non-owner's personal_sign does NOT count (module-native auth) — and a duplicate
#    from owner0 folds once (convergence under duplication).
block:
  const skX = hex32("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a")
  let sx = sigOver(skX)
  doAssert contributorOf(drv, effectJson, sx) == "", "a non-owner is not a signer"
  var dup = events
  dup.add contributeEvent(id, who0, s0)     # owner0 again
  doAssert intentState(dup, foldDrv, id) == "executable", "a duplicate attestation folds once"
  echo "4. non-owner refused; duplicate folds once OK"

echo "eip191_room_test: the room-native eip191 attestation folds + converges — all OK"
