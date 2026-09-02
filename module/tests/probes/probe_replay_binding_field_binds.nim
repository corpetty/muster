## derived-exo-307 s1/c1: the encoded signing payload's bytes change when any one
## of the four context fields (environment, account, slot, expiry) changes,
## holding the rest fixed — each is structurally load-bearing, not decoration.
## Emits {"field_binds": ...} per (payload, field) trial.

import ../../src/intents/signing_payload
import std/random
import ./oracle_emit

var obs: seq[JsonNode]

var r = initRand(0x307)

proc randCtx(r: var Rand): SigningContext =
  SigningContext(
    environment: "env-" & $r.rand(0 .. 99),
    account: "acct-" & $r.rand(0 .. 99),
    slot: "slot-" & $r.rand(0 .. 99),
    expiry: uint64(r.rand(1 .. 1_000_000)))

var allBind = true
for trial in 0 ..< 200:
  let base = SigningPayload(context: randCtx(r),
                            materializationRoot: @[byte(r.rand(0 .. 255)), byte(r.rand(0 .. 255))])
  let baseBytes = encodePayload(base)

  # Mutate exactly one field to a guaranteed-different value; the bytes must change.
  for field in 0 .. 3:
    var m = base
    case field
    of 0: m.context.environment = base.context.environment & "-x"
    of 1: m.context.account = base.context.account & "-x"
    of 2: m.context.slot = base.context.slot & "-x"
    else: m.context.expiry = base.context.expiry + 1
    let binds = encodePayload(m) != baseBytes
    if not binds: allBind = false
    obs.add flag("field_binds", binds)

emitTrials(obs)
doAssert allBind, "a context field did not change the signed payload bytes"
