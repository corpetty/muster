## derived-exo-307 s2/c2: a signature collected under one (environment, account,
## slot, expiry) context verifies at exactly that context and nowhere else.
##
## Sign once at an origin context, then step over an explored space of alternate
## contexts (each differing in one or more fields). Verification must succeed at
## the origin and fail at every alternate — whether the verifier is handed the
## original payload (context mismatch) or a payload doctored to claim the
## alternate context (signature mismatch). Emits
## {"context_state_id": "...", "context_binding_correct": ...}.

import ../../src/intents/signing_payload

const key = "signer-key"
let now = 1000'u64

let origin = SigningContext(environment: "mainnet", account: "acct-A",
                            slot: "slot-0", expiry: 10_000'u64)
let payload = SigningPayload(context: origin, materializationRoot: @[0x11'u8, 0x22, 0x33])
let sig = sign(payload, key)

# Origin verifies.
var allCorrect = verify(sig, payload, key, origin, now)
echo "{\"context_state_id\": \"origin\", \"context_binding_correct\": ",
     (if allCorrect: "true" else: "false"), "}"

let envs = ["mainnet", "testnet", "devnet"]
let accts = ["acct-A", "acct-B", "acct-C"]
let slots = ["slot-0", "slot-1", "slot-2"]
let expiries = [10_000'u64, 20_000'u64, 9_999'u64]

for e in envs:
  for a in accts:
    for s in slots:
      for x in expiries:
        let alt = SigningContext(environment: e, account: a, slot: s, expiry: x)
        if alt == origin: continue          # that's the origin, already checked
        # (i) original payload, verified under the alternate context → must fail.
        let failsOriginal = not verify(sig, payload, key, alt, now)
        # (ii) payload doctored to claim the alternate context, so it would pass
        #      the context check — the signature over the origin bytes must now
        #      fail to match.
        var doctored = payload
        doctored.context = alt
        let failsDoctored = not verify(sig, doctored, key, alt, now)
        let correct = failsOriginal and failsDoctored
        if not correct: allCorrect = false
        echo "{\"context_state_id\": \"", e, "/", a, "/", s, "/", x,
             "\", \"context_binding_correct\": ", (if correct: "true" else: "false"), "}"

doAssert allCorrect, "a signature verified outside the context it was bound to"
