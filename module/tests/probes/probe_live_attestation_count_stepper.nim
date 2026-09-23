## derived-exo-ef1 s5: an in-app approval counts only if its attestation verifies
## against the P the fold itself re-derives from the log and names the same signer as
## the driver signature; a forged, mismatched, or cross-intent attestation is not
## counted.
##
## STEPPER: state = the attestation paired with a driver signature that is ALWAYS
## valid (bob's real in-app approval). Variants replace bob's attestation with:
##   valid                — the original;
##   wrong_signer         — alice's key signing the right P, filed under bob;
##   other_intent         — bob's genuine attestation for a DIFFERENT intent;
##   tampered_provenance  — bob signing a P whose provenance names an extra input;
##   tampered_context     — bob signing P under a context with a different expiry;
##   other_room           — bob's genuine attestation from the same effect proposed in
##                          another room (another context).
## The fold must count the approval (and grade it committed) ONLY for `valid`, under
## every live policy. Catches a fold that checks presence without verifying, and one
## that verifies against the attestation's own claim instead of re-deriving P.
## Build: see live_room.nim.

import ./live_room
import ./oracle_emit
import ../../src/intents/signing_payload as sp
import ../../src/intents/provenance
import ../../src/intents/materialization

const Variants = ["valid", "wrong_signer", "other_intent", "tampered_provenance",
                  "tampered_context", "other_room"]

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc signAs(policy: string, ks: Keystore, p: seq[byte]): string =
  ## Sign P the way an in-app attestation does: secp over keccak256(P), Ed25519 over P.
  if policy == "safe": hexOf(ks.sign(attestationDigest(p)))
  else: hexOf(ks.edSign(p))

proc variantCorrect(variant: string): bool =
  for policy in LivePolicies:
    var r = newRoom("/muster/1/ef1-count-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 5))
    let id2 = r.propose(policy, effectFor(policy, 6))
    discard r.approveAs("bob", id)
    discard r.approveAs("bob", id2)
    let evs0 = r.events()
    let bobAtt = attestEventsFor(evs0, id)
    let bobAtt2 = attestEventsFor(evs0, id2)
    if bobAtt.len != 1 or bobAtt2.len != 1:
      return false                                   # the live path must attest at all
    let bobWho = bobAtt[0].key.split('/')[3]
    # the event set without bob's attestation on `id`
    var base: seq[Event]
    for e in evs0:
      if e.key != bobAtt[0].key: base.add e
    let p = attestationPayload(evs0, liveDriverFor, id)
    var forged = ""
    case variant
    of "valid": forged = bobAtt[0].value
    of "wrong_signer": forged = signAs(policy, aliceKs, p)
    of "other_intent": forged = bobAtt2[0].value
    of "tampered_provenance":
      let drv = liveDriverFor(policy)
      let ctx = intentContext(evs0, id)
      var inputs = intentInputs(evs0, liveDriverFor, id)
      inputs.add SignedInput(class: icExternalRead, logPos: 99, logRef: "0xfeed",
                             accountable: true)
      let mat = canonicalize(drv, effectFromJson(effectJsonOf(evs0, id)))
      let payload = sp.encodePayload(sp.SigningPayload(context: ctx, materializationRoot: mat.bytes))
      forged = signAs(policy, bobKs, signedBytes(payload, buildProvenance(inputs)))
    of "tampered_context":
      var ctx = intentContext(evs0, id)
      ctx.expiry = ctx.expiry + 3600
      forged = signAs(policy, bobKs, attestationPayloadUnder(evs0, liveDriverFor, id, ctx))
    of "other_room":
      var r2 = newRoom("/muster/1/ef1-count-other-" & policy & "/proto")
      let idx = r2.propose(policy, effectFor(policy, 5), nowSec = Now + 60)
      if idx != id: return false
      discard r2.approveAs("bob", idx, Now + 60)
      let a = attestEventsFor(r2.events(), idx)
      if a.len != 1: return false
      forged = a[0].value
    else: discard
    var evs = base
    evs.add attestEvent(id, bobWho, 1, forged)
    let counted = countedApprovals(evs, id)
    let grade = gradeOf(approvalGrades(evs, liveDriverFor, id), bobWho, 1)
    if variant == "valid":
      if counted != 1 or grade != agCommitted: return false
    else:
      if counted != 0 or grade == agCommitted: return false
  true

proc state(v: string): JsonNode =
  %*{"variant": v, "count_correct": variantCorrect(v)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "variant", "valid")
var succ: seq[JsonNode]
for v in Variants:
  if v != here: succ.add state(v)
emitSuccessors(succ)

if arg == nil:
  for v in Variants:
    doAssert variantCorrect(v), "the fold counted an approval whose attestation is " & v
