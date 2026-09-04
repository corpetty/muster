## In-app signing (identity layer, increment 1): the local identity signs its OWN
## contributions — no pasted fixture. This proves the capability the module wires up:
## with the local identity IN the room's roster (members-derived, currentRoster()),
## an Ed25519 endorsement by that identity is a valid contribution that folds to
## executable. Keystore.edSign delegates straight to this EncKeys.edSign (verified by
## the module build); testing the enc key directly keeps this runnable without the
## secp256k1 nimble deps the full keystore pulls in.

import std/strutils
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/threshold
import ../src/drivers/frost
import ../src/coordination/intents
import ../src/crypto/curve25519

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc sigHex(sig: Ed25519Sig): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in sig: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# The user's own encryption identity — what the keystore holds and edSign signs with.
let meKeys = encFromSeed(seed(10))
let me = meKeys.identity().ed            # my Ed25519 key — this goes in the roster

let effectJson = """{"to":"0xabc","value":42,"nonce":0}"""

# ── threshold: I am the (only) member, so the roster is [me] and k = 1. I approve
#    IN-APP — sign the materialization with MY key (keystore.edSign == this). No paste.
block:
  let drv = newThresholdDriver(@[me], k = 1)
  let id = intentIdFor(effectJson, "threshold")
  let mat = canonicalize(drv, effectFromJson(effectJson))
  let mySig = sigHex(edSign(meKeys, mat.bytes))
  let who = contributorOf(drv, effectJson, mySig)
  doAssert who.len > 0, "my own signature is a valid contribution (I'm in the roster)"
  let foldDrv: DriverFor = proc(kind: string): Driver = drv
  let events = @[policyDeclEvent(id, "threshold"), proposeEvent(id, effectJson),
                 contributeEvent(id, who, mySig, round = 1)]
  doAssert intentState(events, foldDrv, id) == "executable",
           "in-app approval by the sole member reaches executable — no pasted fixture"
  echo "1. threshold: my own edSign is a valid in-app contribution → executable OK"

# ── FROST: same, but I endorse BOTH rounds with my own key (rounds=2, k=1).
block:
  let drv = newFrostDriver(@[me], k = 1)
  let id = intentIdFor(effectJson, "frost")
  let mat = canonicalize(drv, effectFromJson(effectJson))
  let mySig = sigHex(edSign(meKeys, mat.bytes))
  let who = contributorOf(drv, effectJson, mySig)
  let foldDrv: DriverFor = proc(kind: string): Driver = drv
  let events = @[policyDeclEvent(id, "frost"), proposeEvent(id, effectJson),
                 contributeEvent(id, who, mySig, round = 1),
                 contributeEvent(id, who, mySig, round = 2)]
  doAssert intentState(events, foldDrv, id) == "executable",
           "in-app FROST: I endorse both rounds with my own key → executable"
  echo "2. frost: my own edSign endorses both rounds in-app → executable OK"

# ── a non-member's signature over a roster that excludes it is refused (invariant 6).
block:
  let outsider = encFromSeed(seed(20))
  let drv = newThresholdDriver(@[me], k = 1)          # roster is [me], not the outsider
  let mat = canonicalize(drv, effectFromJson(effectJson))
  let theirSig = sigHex(edSign(outsider, mat.bytes))
  doAssert contributorOf(drv, effectJson, theirSig).len == 0,
           "a non-member's in-app signature is not a valid contribution"
  echo "3. a non-member's signature is refused OK"

echo "in_app_signing_test: the local identity signs its own contributions OK"
