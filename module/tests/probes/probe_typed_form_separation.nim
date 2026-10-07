## exo-149.6 (ADR-017 K6b): the two forms of an attestation and of an identity binding
## never cross. A signature over the typed (EIP-712) document never verifies as a
## hash-input one (keccak256(P), linkDigest), and the reverse: the EIP-712 hash is
## keccak256(0x19 0x01 ‖ domainSeparator ‖ hashStruct), which no hash-input digest equals.
## Emits {"forms_separate": ...} per trial.

import ../../src/coordination/[attest, attest_typed]
import ../../src/intents/signing_payload
import ../../src/crypto/[secp256k1, curve25519, binding]
import std/random
import ./oracle_emit

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)])

var obs: seq[JsonNode]
var r = initRand(0x1497)
var separate = true

for trial in 0 ..< 100:
  var sk: array[32, byte]
  for i in 0 ..< 32: sk[i] = byte(r.rand(1 .. 255))
  let me = hexOf(addressOf(sk))
  let ctx = SigningContext(environment: "eip155:" & $r.rand(1 .. 99999), account: "a" & $trial,
                           slot: $r.rand(1 .. 9), expiry: uint64(r.rand(10 .. 1_000_000)))
  var mat, p: seq[byte]
  for _ in 0 ..< 32: mat.add byte(r.rand(0 .. 255))
  for _ in 0 ..< r.rand(1 .. 100): p.add byte(r.rand(0 .. 255))
  let typed = hexOf(signRecoverable(attestationTypedHash(ctx, mat, 2, p), sk))
  let raw = hexOf(signRecoverable(attestationDigest(p), sk))
  var ok = verifyAttestation(me, p, raw) and verifyTypedAttestation(me, ctx, mat, 2, p, typed) and
           not verifyAttestation(me, p, typed) and not verifyTypedAttestation(me, ctx, mat, 2, p, raw)
  var enc: EncIdentity
  for i in 0 ..< 32: (enc.ed[i] = byte(r.rand(0 .. 255)); enc.x[i] = byte(r.rand(0 .. 255)))
  let lctx = LinkContext(account: "room-" & $trial, slot: "1", expiry: 2_000_000)
  let tst = LinkStatement(enc: enc, ctx: lctx, sig: signRecoverable(bindingTypedHash(enc, lctx), sk))
  let hst = LinkStatement(enc: enc, ctx: lctx, sig: signRecoverable(linkDigest(enc, lctx), sk))
  ok = ok and hexOf(bindingSignerAs(afEip712, tst, 1)) == me and
       hexOf(bindingSignerAs(afHashInput, hst, 1)) == me and
       hexOf(bindingSignerAs(afHashInput, tst, 1)) != me and
       hexOf(bindingSignerAs(afEip712, hst, 1)) != me
  if not ok: separate = false
  obs.add flag("forms_separate", ok)

emitTrials(obs)
doAssert separate, "a signature in one form verified in the other"
