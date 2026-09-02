## derived-exo-307 s2/c2: a signature collected under one (environment, account,
## slot, expiry) context verifies at exactly that context and nowhere else.
##
## STEPPER (exo-dbc): sign once at an origin context; state is the context being
## verified at, "env/account/slot/expiry", with the spec's initial id "origin"
## naming the one the signature was bound to. Successors are every other context
## in the space. Verification must succeed at the origin and fail everywhere else
## — whether the verifier is handed the original payload (context mismatch) or a
## payload doctored to claim the alternate context (signature mismatch).

import ../../src/intents/signing_payload
import std/strutils
import ./oracle_emit

const key = "signer-key"
let now = 1000'u64

let origin = SigningContext(environment: "mainnet", account: "acct-A",
                            slot: "slot-0", expiry: 10_000'u64)
let payload = SigningPayload(context: origin, materializationRoot: @[0x11'u8, 0x22, 0x33])
let sig = sign(payload, key)

let envs = ["mainnet", "testnet", "devnet"]
let accts = ["acct-A", "acct-B", "acct-C"]
let slots = ["slot-0", "slot-1", "slot-2"]
let expiries = [10_000'u64, 20_000'u64, 9_999'u64]

proc contextId(c: SigningContext): string =
  c.environment & "/" & c.account & "/" & c.slot & "/" & $c.expiry

proc contextIds(): seq[string] =
  for e in envs:
    for a in accts:
      for s in slots:
        for x in expiries:
          result.add contextId(SigningContext(environment: e, account: a, slot: s, expiry: x))

proc parseContext(id: string): SigningContext =
  if id == "origin": return origin
  let p = id.split('/')
  doAssert p.len == 4, "malformed context_state_id: " & id
  SigningContext(environment: p[0], account: p[1], slot: p[2], expiry: parseBiggestUInt(p[3]))

proc bindingCorrect(ctx: SigningContext): bool =
  if ctx == origin:
    # The origin must actually verify — otherwise "fails everywhere" would hold
    # vacuously for a signature that verifies nowhere at all.
    return verify(sig, payload, key, origin, now)
  # (i) original payload verified under the alternate context -> must fail.
  if verify(sig, payload, key, ctx, now): return false
  # (ii) payload doctored to claim the alternate context, so it passes the
  #      context check — the signature over the origin bytes must now fail.
  var doctored = payload
  doctored.context = ctx
  not verify(sig, doctored, key, ctx, now)

proc state(id: string): JsonNode =
  let ctx = parseContext(id)
  %*{"context_state_id": (if ctx == origin: "origin" else: id),
     "context_binding_correct": bindingCorrect(ctx)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "context_state_id", "origin")
let hereCtx = parseContext(here)
var succ: seq[JsonNode]
for id in contextIds():
  if parseContext(id) != hereCtx: succ.add state(id)
emitSuccessors(succ)

if arg == nil:
  doAssert bindingCorrect(origin), "the signature did not verify at its own context"
  for id in contextIds():
    doAssert bindingCorrect(parseContext(id)),
      "a signature verified outside the context it was bound to"
