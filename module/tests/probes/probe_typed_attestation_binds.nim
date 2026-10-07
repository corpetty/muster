## exo-149.6 (ADR-017 K6b): a typed (EIP-712) attestation verifies against the context,
## materialization root, count of accounted inputs and P the verifier recomputed, and is
## refused when any one of them, or the domain, differs — every rendered field is
## load-bearing, so what a person read in the signer is what was attested.
## Emits {"typed_field_binds": ...} per (attestation, field) trial.

import ../../src/coordination/attest_typed
import ../../src/intents/signing_payload
import ../../src/crypto/secp256k1
import ../../src/wallet/keystore_legs
import std/random
import ./oracle_emit

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)])

var obs: seq[JsonNode]
var r = initRand(0x1496)
var allBind = true

proc randBytes(r: var Rand, lo, hi: int): seq[byte] =
  for _ in 0 ..< r.rand(lo .. hi): result.add byte(r.rand(0 .. 255))

for trial in 0 ..< 100:
  var sk: array[32, byte]
  for i in 0 ..< 32: sk[i] = byte(r.rand(1 .. 255))
  let me = hexOf(addressOf(sk))
  let ctx = SigningContext(
    environment: (if r.rand(0 .. 1) == 0: "eip155:" & $r.rand(1 .. 99999) else: "room-" & $r.rand(0 .. 99)),
    account: "acct-" & $r.rand(0 .. 99), slot: $r.rand(1 .. 99),
    expiry: uint64(r.rand(1 .. 2_000_000_000)))
  let mat = randBytes(r, 0, 64)
  let inputs = r.rand(1 .. 20)
  let p = randBytes(r, 1, 200)
  let sig = hexOf(signRecoverable(attestationTypedHash(ctx, mat, inputs, p), sk))
  let ok = verifyTypedAttestation(me, ctx, mat, inputs, p, sig)
  if not ok: allBind = false
  obs.add flag("typed_field_binds", ok)
  for field in 0 .. 7:
    var c = ctx
    var m = mat
    var n = inputs
    var q = p
    case field
    of 0: c.environment = c.environment & "0"
    of 1: c.account = c.account & "-x"
    of 2: c.slot = c.slot & "1"
    of 3: c.expiry = c.expiry + 1
    of 4: m.add 0'u8
    of 5: n = n + 1
    of 6: q[0] = q[0] xor 0x80
    else: discard
    let refused =
      if field == 7:
        # the domain alone: the same message under another domain hashes elsewhere
        var td = attestationTypedData(ctx, mat, inputs, p)
        td["domain"]["version"] = %"2"
        typedDataHash(td) != attestationTypedHash(ctx, mat, inputs, p)
      else: not verifyTypedAttestation(me, c, m, n, q, sig)
    if not refused: allBind = false
    obs.add flag("typed_field_binds", refused)

emitTrials(obs)
doAssert allBind, "a rendered field, P or the domain did not bind the typed attestation"
