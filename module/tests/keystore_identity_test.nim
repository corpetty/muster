## A keystore_module account as this member's authorization identity (exo-149.5 K5).
## Held: the key binding is requested once, at selection — one digest leg over exactly
## linkDigest(enc identity, context), the context the account itself, scoped
## "keystore_module", valid 30 days; what comes back becomes a binding statement only
## when it recovers to the chosen account, and it survives the wire encoding; and a
## stored binding reads as none / valid / expiring (inside a day) / expired / invalid
## (garbage, another identity, another account). Design: docs/design/keystore-module-backend.md
## §4 option C.

import std/[json, strutils]
import ../src/crypto/secp256k1
import ../src/crypto/curve25519
import ../src/crypto/binding
import ../src/crypto/keystore
import ../src/wallet/keystore_legs
import ../src/wallet/keystore_identity

proc hexOf(b: openArray[byte]): string =
  result = "0x"
  for x in b: result.add toHex(x).toLowerAscii()

var sk, other: array[32, byte]
for i in 0 ..< 32: (sk[i] = byte(i + 9); other[i] = byte(77 + i))
let account = hexOf(addressOf(sk))
var seed: array[32, byte]
for i in 0 ..< 32: seed[i] = 5
let me = newInMemoryKeystore(sk, seed).encIdentity()
var seed2: array[32, byte]
for i in 0 ..< 32: seed2[i] = 6
let notMe = newInMemoryKeystore(other, seed2).encIdentity()
const Now = 1_800_000_000'u64

block contextAndRequest:
  let ctx = keystoreBindingContext(account.toUpperAscii().replace("0X", "0x"), Now)
  doAssert ctx.account == account and ctx.slot == "keystore_module"
  doAssert ctx.expiry == Now + uint64(KeystoreBindingTtlS)
  let req = bindingApproval(me, ctx, account)
  doAssert req.intent["address"].getStr() == account and req.intent["legs"].len == 1
  let leg = req.intent["legs"][0]
  doAssert leg["kind"].getStr() == "digest" and "Muster key binding" in leg["purpose"].getStr()
  doAssert leg["digest"].getStr() == hexOf(linkDigest(me, ctx)) and req.legs[0].hash == linkDigest(me, ctx)
  doAssert req.legs[0].kind == "binding"
  echo "1. one digest leg over exactly linkDigest, scoped to the account, valid 30 days OK"

block statement:
  let ctx = keystoreBindingContext(account, Now)
  let st = bindingFromSignature(me, ctx, hexOf(signRecoverable(linkDigest(me, ctx), sk)), account, Now)
  doAssert hexOf(bindingSigner(st, Now)) == account and st.enc == me
  let back = decodeLink(encodeLink(st))
  doAssert hexOf(bindingSigner(back, Now)) == account
  doAssertRaises(KeystoreLegError):
    discard bindingFromSignature(me, ctx, hexOf(signRecoverable(linkDigest(me, ctx), other)), account, Now)
  doAssertRaises(KeystoreLegError): discard bindingFromSignature(me, ctx, "0x1234", account, Now)
  echo "2. a binding stands only if it recovers to the chosen account; it survives the wire form OK"

block states:
  let ctx = keystoreBindingContext(account, Now)
  let hex = hexOf(encodeLink(bindingFromSignature(me, ctx, hexOf(signRecoverable(linkDigest(me, ctx), sk)),
                                                  account, Now)))
  doAssert bindingState("", account, me, Now) == "none"
  doAssert bindingState(hex, account, me, Now) == "valid"
  doAssert bindingState(hex, account, me, ctx.expiry - 3600) == "expiring"
  doAssert bindingState(hex, account, me, ctx.expiry + 1) == "expired"
  doAssert bindingState("0xdeadbeef", account, me, Now) == "invalid"
  doAssert bindingState(hex, account, notMe, Now) == "invalid"
  doAssert bindingState(hex, "0x" & "11".repeat(20), me, Now) == "invalid"
  echo "3. a stored binding reads none / valid / expiring / expired / invalid OK"

echo "keystore_identity_test: all passed"
