## derived-exo-307 s3/c3: a signing payload past its committed expiry fails
## verification, even when every other field is otherwise valid — expiry is
## enforced independently of the other three fields matching. Emits
## {"expiry_rejected": ...}.

import ../../src/intents/signing_payload
import std/random

var r = initRand(0x3073)
const key = "signer-key"
var allRejected = true

for trial in 0 ..< 200:
  let expiry = uint64(r.rand(1 .. 1_000_000))
  let nowPast = expiry + uint64(r.rand(1 .. 1000))   # strictly past expiry
  let ctx = SigningContext(environment: "env-" & $r.rand(0 .. 9),
                           account: "acct-" & $r.rand(0 .. 9),
                           slot: "slot-" & $r.rand(0 .. 9), expiry: expiry)
  let p = SigningPayload(context: ctx, materializationRoot: @[byte(r.rand(0 .. 255))])
  let sig = sign(p, key)

  # Same context, correct key/signature — only the clock is past expiry.
  let rejectedPastExpiry = not verify(sig, p, key, ctx, nowPast)
  # And it WOULD verify with a clock at/before expiry — proving expiry alone
  # rejected it, not some other field.
  let validAtExpiry = verify(sig, p, key, ctx, expiry)

  let ok = rejectedPastExpiry and validAtExpiry
  if not ok: allRejected = false
  echo "{\"expiry_rejected\": ", (if ok: "true" else: "false"), "}"

doAssert allRejected, "an expired payload verified, or expiry was not the reason it failed"
