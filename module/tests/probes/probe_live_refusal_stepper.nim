## derived-exo-ef1 s2: coordinate_contribute refuses to sign and publishes nothing
## when any input that reached the materialization cannot be accounted for, and
## signs when every input can be.
##
## STEPPER: state = how many of the proposal's declared-sourced fields have NO source
## record in the log (0..2). Each state's verdict quantifies over every live policy and
## every choice of which fields go unrecorded, driving the hosted contribute path: an
## approval must publish nothing (no sig, no attestation) exactly when the count is
## non-zero, and must publish a sig AND its attestation when it is zero — so a
## refuse-everything implementation is a counterexample as surely as a sign-anything one.
## Build: see live_room.nim.

import ./live_room
import ./oracle_emit

proc sourcedFields(policy: string): seq[string] =
  if policy == "safe": @["value", "nonce"] else: @["text", "effect"]

proc fieldValue(policy, field: string, n: int): string =
  case field
  of "value": $n
  of "nonce": "0"
  of "text": "probe " & $n
  of "effect": "statement"
  else: ""

proc decisionCorrect(unaccountable: int): bool =
  for policy in LivePolicies:
    let fields = sourcedFields(policy)
    for mask in 0 ..< (1 shl fields.len):
      var missing: seq[string]
      for k, f in fields:
        if (mask and (1 shl k)) != 0: missing.add f
      if missing.len != unaccountable: continue
      var srcs = ""
      for f in fields: srcs.add (if srcs.len > 0: "," else: "") & "\"" & f & "\":\"read\""
      var r = newRoom("/muster/1/ef1-refuse-" & policy & "-" & $mask & "/proto")
      let id = r.propose(policy, effectFor(policy, 7, "\"sources\":{" & srcs & "}"))
      for f in fields:
        if f notin missing:
          r.alice.publish(readEvent(id, f, "rpc://probe", fieldValue(policy, f, 7)))
      let before = r.events().len
      discard r.approveAs("alice", id)
      let evs = r.events()
      let published = evs.len > before
      let attested = sigEventsFor(evs, id).len == 1 and attestEventsFor(evs, id).len == 1
      if unaccountable > 0:
        if published: return false        # signed with an unaccountable input
      else:
        if not attested: return false     # refused (or unattested) with every input accounted for
  true

proc state(n: int): JsonNode =
  %*{"unaccountable_count": n, "decision_correct": decisionCorrect(n)}

let arg = oracleStateArg()
let here = oracleStateInt(arg, "unaccountable_count", 0)
var succ: seq[JsonNode]
for n in 0 .. 2:
  if n != here: succ.add state(n)
emitSuccessors(succ)

if arg == nil:
  for n in 0 .. 2:
    doAssert decisionCorrect(n), "live sign/refuse did not track input accountability (unaccountable=" & $n & ")"
