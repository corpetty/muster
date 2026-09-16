## Muster-issued authorizations (M7 local half, exo-002.7): issued by this instance's
## secp key, replay-bound (inv 2), and checked refuse-on-mismatch — a wrong root, an
## expired grant, a tampered field, or an untrusted issuer is refused with a reason;
## the JSON form round-trips. Needs the secp closure + libsodium (keystore).

import std/[json, strutils]
import ../src/crypto/secp256k1
import ../src/crypto/keystore
import ../src/intents/authorization

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
let ks = newInMemoryKeystore(seed(7), seed(8))
let other = newInMemoryKeystore(seed(9), seed(10))
let root = @[1'u8, 2, 3, 4]
let a = issueAuthorization(ks, "0xabc", "safe.execute", "chain:31337", "safe:0x5fbd", root, 1_000)

block:
  let r = checkAuthorization(a, now = 500, expectedRoot = root, allowedIssuers = [ks.address()])
  doAssert r.ok and r.issuer == ks.address(), r.reason
  doAssert checkAuthorization(a, now = 500).ok, "any root / any issuer when the host supplies none"
  echo "1. an authorization for the agreed root, before expiry, from a trusted issuer verifies OK"

block:
  doAssert not checkAuthorization(a, now = 1_001).ok
  doAssert "expired" in checkAuthorization(a, now = 1_001).reason
  let wrong = checkAuthorization(a, now = 500, expectedRoot = @[9'u8])
  doAssert not wrong.ok and "root does not match" in wrong.reason
  let untrusted = checkAuthorization(a, now = 500, allowedIssuers = [other.address()])
  doAssert not untrusted.ok and "not trusted" in untrusted.reason
  var t = a; t.capability = "lez_core.transfer_private"
  doAssert not checkAuthorization(t, now = 500).ok, "changing any committed field breaks recovery"
  t = a; t.context.slot = "0xdef"
  doAssert not checkAuthorization(t, now = 500).ok
  t = a; t.issuer = other.address()
  doAssert "does not recover" in checkAuthorization(t, now = 500).reason
  echo "2. expired / wrong root / untrusted issuer / tampered capability / slot / issuer all REFUSED OK"

block:
  let j = a.toJson()
  doAssert j["format"].getStr() == "muster.authorization.v1" and j["slot"].getStr() == "0xabc"
  let back = authorizationFromJson(j)
  doAssert checkAuthorization(back, now = 500, expectedRoot = root, allowedIssuers = [ks.address()]).ok
  doAssert authorizationDigest(back) == authorizationDigest(a)
  var refused = false
  try: discard authorizationFromJson(%*{"format": "nope"})
  except ValueError: refused = true
  doAssert refused
  doAssert capabilityOf("invoke", """{"module":"lez_core","method":"transfer_private"}""") == "lez_core.transfer_private"
  doAssert capabilityOf("safe", "") == "safe.execute" and capabilityOf("threshold", "") == "room.attest"
  echo "3. JSON round-trips; a foreign format raises; capability names derive from the policy + effect OK"

echo "authorization_test: all OK"
