## derived-exo-ef1 s3: the record committed in P is reduced from the log with one
## entry per input that reached the bytes — the proposal, bound material shares, the
## policy declaration, and baked-in external reads — each naming its class and the
## event's content id, with two-way coverage.
##
## STEPPER: state = a proposal shape. Successors are the other shapes. Each state's
## verdict, over every live policy, builds the room through the hosted path and checks:
##   1. the inputs equal EXACTLY the expected source events (by content id + class):
##      nothing missing, nothing padded, no index standing in for an id;
##   2. every expected input is load-bearing: perturbing that one source event (same
##      field value, different content) changes P;
##   3. the attestation alice's in-app approval published verifies over that P.
## Build: see live_room.nim.

import std/sets
import ./live_room
import ./oracle_emit

const Shapes = ["plain", "read1", "material1", "read_material"]

proc build(policy, shape: string, variant: string): (Room, string, seq[(string, InputClass)]) =
  ## Returns the room, the intent id, and the EXPECTED inputs as (event key, class).
  let field = (if policy == "safe": "value" else: "text")
  let valueText = (if policy == "safe": "9" else: "probe 9")
  let toField = (if policy == "safe": "to" else: "text")
  var extra = ""
  case shape
  of "read1": extra = "\"sources\":{\"" & field & "\":\"read\"}"
  of "material1": extra = "\"sources\":{\"" & toField & "\":\"material\"}"
  of "read_material":
    if policy == "safe":
      extra = "\"sources\":{\"value\":\"read\",\"to\":\"material\"}"
    else:
      extra = "\"sources\":{\"text\":\"read\"}"   # a statement has one field
  else: discard
  var r = newRoom("/muster/1/ef1-cover-" & policy & "-" & shape & "/proto")   # same topic for both variants: only provenance may differ
  let id = r.propose(policy, effectFor(policy, 9, extra))
  var expect = @[("intent/" & id & "/propose", icPeerMessage),
                 ("intent/" & id & "/policy", icPeerMessage),
                 ("intent/" & id & "/context", icPeerMessage)]
  if shape in ["read1", "read_material"]:
    r.alice.publish(readEvent(id, field, "rpc://" & variant, valueText))
    expect.add ("intent/" & id & "/read/" & field, icExternalRead)
  if shape == "material1" or (shape == "read_material" and policy == "safe"):
    let pub = (if policy == "safe": "0x1111111111111111111111111111111111111111" else: "probe 9")
    r.bob.publishAuthored(bobKs, materialShareEvent(id, "payee", bobEncId, pub, "address-" & variant,
                                                    "account", toField))   # signed, as Bob's module does (exo-f76)
    expect.add ("intent/" & id & "/material/payee/" & bobEncId, icPeerMessage)
  (r, id, expect)

proc shapeCorrect(shape: string): bool =
  for policy in LivePolicies:
    var (r, id, expect) = build(policy, shape, "a")
    let evs = r.events()
    var byKey = initTable[string, string]()     # key -> content id
    for e in evs: byKey[e.key] = eventId(e)
    let inputs = intentInputs(evs, liveDriverFor, id)
    # 1. two-way: inputs == expected, by content id and class
    var want = initHashSet[string]()
    for (k, c) in expect:
      if k notin byKey: return false            # the live path never published it
      want.incl byKey[k] & "|" & $c
    var got = initHashSet[string]()
    for i in inputs:
      if not i.accountable or i.logRef.len == 0: return false
      got.incl i.logRef & "|" & $i.class
    if got != want or inputs.len != expect.len: return false
    # 2. each non-structural input is load-bearing: a different source event for the
    #    same value changes P.
    let p = attestationPayload(evs, liveDriverFor, id)
    if p.len == 0: return false
    if shape != "plain":
      var (r2, id2, _) = build(policy, shape, "b")
      if id2 != id: return false
      if attestationPayload(r2.events(), liveDriverFor, id2) == p: return false
    # 3. the live approval commits to exactly this P
    discard r.approveAs("alice", id)
    let evs2 = r.events()
    let atts = attestEventsFor(evs2, id)
    if atts.len != 1: return false
    if not verifyAttestation(atts[0].key.split('/')[3], p, atts[0].value): return false
  true

proc state(shape: string): JsonNode =
  %*{"shape": shape, "coverage_two_way": shapeCorrect(shape)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "shape", "plain")
var succ: seq[JsonNode]
for s in Shapes:
  if s != here: succ.add state(s)
emitSuccessors(succ)

if arg == nil:
  for s in Shapes:
    doAssert shapeCorrect(s), "live provenance coverage failed for shape " & s
