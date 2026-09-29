## exo-093 — an event whose history leaves the intent cannot block its audit.
##
## The audit file is parent-closed, and since exo-96d the export refuses rather than hand
## over a file its verifier would refuse. Any epoch-key holder chooses an event's parents,
## so an event the file had to carry, parented outside the intent's record, blocked the
## export:
##   - every attestation under an approval's key was carried: a forged one parented on a
##     room message blocked the export, and on a pasted approval the fold rejected it too;
##   - the copy that stood for an approval was the first valid one in canonical order: a
##     copy of a member's signature parented on a room message, ground to sort first, was
##     carried as the approval, and approvals made after it linked it.
## An intent's record is closed: its lineage, and the copies of its approvals whose parents
## lie in the record. An attestation belongs to the intent only if it links nothing but
## copies of its own approval there; the copy that stands for an approval is one whose
## parents lie there.
##   1. a forged attestation on a committed approval, parented on a room message: the
##      approval stays committed, and the file verifies;
##   2. the same on a pasted approval: it is no attestation of this intent, so the approval
##      stays counted (unattested), and the file verifies;
##   3. a forged attestation parented on junk under another name: the same;
##   4. a valid copy of Alice's signature parented on a room message and sorted first,
##      before Bob approves: Bob's approval links a copy inside the record, the views cite
##      that copy, and the file verifies.
## Build: see probes/live_room.nim (the secp closure + stint + libsodium).

import std/[strutils, sequtils, sets]
import ../src/drivers/threshold
import ../src/coordination/flow
import ./probes/audit_room

proc proposeIdsOf(evs: seq[Event], id: string): seq[EventId] =
  for e in evs:
    if e.key == "intent/" & id & "/propose": result.add eventId(e)

proc messageIds(r: Room, n: int): seq[EventId] =
  ## n room messages from Bob: events outside every intent's record.
  for i in 0 ..< n: r.messageAs("bob", int64(9_000 + i), "aside " & $i, uint64(9_000 + i))
  for e in r.events():
    if e.key.startsWith("message/"): result.add eventId(e)

proc nameOf(r: Room, id, who: string): string =
  ## The name <who>'s approval of intent <id> is published under.
  for g in approvalGrades(r.events(), liveDriverFor, id):
    if approvedByMe(r.events(), id, @[g.who], ksOf(who).encIdentity(), myContributorNames(ksOf(who))):
      return g.who

proc verifies(label: string, r: Room, id: string, approvals: int) =
  let file = r.exportAs("alice", id)
  doAssert file.ok, label & ": export refused: " & file.reason
  let v = verifyAudit(file.bytes)
  doAssert v.ok, label & ": the audit file does not verify: " & v.reason
  doAssert v.approvals.len == approvals, label & ": " & $v.approvals.len & " approvals in the file"

proc forgedAttestationOn(label: string, policy: string, pasted: bool, parentOf: proc (r: var Room, id: string): EventId) =
  var r = newRoom("/muster/1/093-" & label & "-" & policy & "/proto")
  let id = r.propose(policy, effectFor(policy, 900 + label.len))
  if pasted: doAssert r.pasteAs("alice", policy, id) == "collecting"
  else: doAssert r.approveAs("alice", id) == "collecting"
  doAssert r.approveAs("bob", id) == "executable"
  let who = r.nameOf(id, "alice")
  doAssert who.len > 0, label & ": Alice's approval"
  let parent = parentOf(r, id)
  let forged = attestEvent(id, who, 1, "0x" & "cd".repeat(65), parents = @[parent])
  r.bob.publish(forged)
  let evs = r.events()
  doAssert intentState(evs, liveDriverFor, id) == "executable",
    policy & " " & label & ": a forged attestation outside the record took Alice's approval out of the count"
  let want = (if pasted: agUnattested else: agCommitted)
  doAssert gradeOf(approvalGrades(evs, liveDriverFor, id), who, 1) == want,
    policy & " " & label & ": Alice's approval is graded " & $gradeOf(approvalGrades(evs, liveDriverFor, id), who, 1)
  for p in logProvenance(evs, liveDriverFor):
    doAssert not (p.kind == "attest" and p.seq == canonicalOrder(evs).mapIt(eventId(it)).find(eventId(forged))),
      policy & " " & label & ": the provenance lists an attestation outside the record"
  verifies(policy & " " & label, r, id, 2)

for policy in ["threshold", "safe"]:
  # ── 1 and 2. a forged attestation parented on a room message ───────────────────
  let onMessage = proc (r: var Room, id: string): EventId = r.messageIds(1)[0]
  forgedAttestationOn("msg-committed", policy, pasted = false, onMessage)
  echo "1. ", policy, ": a forged attestation parented on a room message leaves a committed approval committed; the audit verifies OK"
  forgedAttestationOn("msg-pasted", policy, pasted = true, onMessage)
  echo "2. ", policy, ": the same on a pasted approval — no attestation of this intent; still counted, the audit verifies OK"

  # ── 3. a forged attestation parented on junk under another name ─────────────────
  let onJunk = proc (r: var Room, id: string): EventId =
    let junk = contributeEvent(id, "ed:" & "ef".repeat(32), "0x" & "00".repeat(65),
                               parents = proposeIdsOf(r.events(), id))
    r.bob.publish(junk)
    eventId(junk)
  forgedAttestationOn("junk-pasted", policy, pasted = true, onJunk)
  echo "3. ", policy, ": a forged attestation parented on junk is no attestation of this intent; the audit verifies OK"

  # ── 4. a copy of Alice's signature parented on a room message, sorted first ─────
  block:
    var r = newRoom("/muster/1/093-copy-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 950))
    doAssert r.approveAs("alice", id) == "collecting"
    let orig = sigEventsFor(r.events(), id)[0]
    var copy: Event
    var ahead = false
    for m in r.messageIds(16):
      copy = Event(parents: @[m], key: orig.key, value: orig.value)
      let order = canonicalOrder(r.events() & @[copy]).mapIt(eventId(it))
      if order.find(eventId(copy)) < order.find(eventId(orig)): (ahead = true; break)
    doAssert ahead, policy & ": no copy sorts ahead of the original"
    r.bob.publish(copy)
    doAssert r.approveAs("bob", id) == "executable"
    let evs = r.events()
    for e in sigEventsFor(evs, id):
      doAssert eventId(copy) notin e.parents, policy & ": an approval links the copy whose history leaves the intent"
    for g in approvalGrades(evs, liveDriverFor, id):
      doAssert eventId(g.sig) != eventId(copy), policy & ": the copy outside the record stands for Alice's approval"
    verifies(policy & ": a copy parented on a room message", r, id, 2)
    echo "4. ", policy, ": a copy of a signature parented outside the intent stands for nothing; the audit verifies OK"

# ── exo-dc6: the two ways left after exo-093 ─────────────────────────────────────────
# 5. Multi-round: a copy may link only copies of its own round or earlier ones; honest ones
#    do, since a member contributes to the round being collected and links the approvals
#    graded so far. So the record of rounds up to r never depends on a later round, and
#    everything it holds for a reached round the file can carry. An attacker's copy of
#    Alice's round-1 approval parented on a copy under round 2 (not yet reached), and a
#    forged attestation parented on it, is no part of the record.
# 6. A settlement entry belongs to the record only if its parents lie in the intent's
#    lineage (an honest one has none). A fake submit parented on a room message is not the
#    intent's settlement: no reader counts it: not the fold, the activity feed, the
#    provenance or the flow view. The file then never needs to carry it.
# 7. The same for a fake final after an honest submit.
type TwoRoundThreshold = ref object of ThresholdDriver
method describe(d: TwoRoundThreshold): DriverDescriptor =
  result = procCall describe(ThresholdDriver(d))
  result.rounds = 2

proc verifiesWith(label: string, r: Room, dFor: DriverFor, id: string, approvals: int, stage: string) =
  let file = exportAudit(r.alice.log.allEvents(), dFor, id, aliceKs)
  doAssert file.ok, label & ": export refused: " & file.reason
  let v = verifyAudit(file.bytes)
  doAssert v.ok, label & ": the audit file does not verify: " & v.reason
  doAssert v.approvals.len == approvals and v.stage == stage,
    label & ": " & $v.approvals.len & " approvals, stage " & v.stage

block:
  let two = TwoRoundThreshold(roster: @[aliceKs.encIdentity().ed, bobKs.encIdentity().ed], k: 2)
  let dFor: DriverFor = proc(kind: string): Driver = (if kind == "threshold": Driver(two) else: liveDriverFor(kind))
  var r = newRoom("/muster/1/dc6-rounds/proto")
  let id = liveProposeIntent(r.alice, aliceKs, dFor, "threshold", effectFor("threshold", 990), int64(Now), 1,
                             account = r.topic, ttlSec = Ttl)
  doAssert liveContribute(r.alice, aliceKs, dFor, id, "", "", bindCtx(), Now) == "collecting"
  r.bob.poll()
  let orig = sigEventsFor(r.events(), id)[0]
  let nameA = orig.key.split('/')[3]
  let x = contributeEvent(id, nameA, orig.value, round = 2, parents = proposeIdsOf(r.events(), id))
  let c = contributeEvent(id, nameA, orig.value, round = 1, parents = @[eventId(x)])
  let forged = attestEvent(id, nameA, 1, "0x" & "cd".repeat(64), parents = @[eventId(c)])
  r.bob.publish(x); r.bob.publish(c); r.bob.publish(forged)
  let evs = r.events()
  let it = reduceIntents(evs, dFor)[id]
  doAssert $it.state == "collecting" and it.collection.round == 1, "two rounds: round 1 is still open"
  doAssert gradeOf(approvalGrades(evs, dFor, id), nameA, 1) == agCommitted
  for g in approvalGrades(evs, dFor, id):
    doAssert eventId(forged) notin g.attests.mapIt(eventId(it)),
      "the forged attestation, parented through a later round, is carried as the intent's"
  verifiesWith("a chain through a round not yet reached", r, dFor, id, 1, "collecting")
  echo "5. multi-round: a copy parented on a later round's copy, and an attestation on it, are no part of the record; the audit verifies OK"

for policy in LivePolicies:
  # ── 6. a fake submit parented on a room message ─────────────────────────────────
  block:
    var r = newRoom("/muster/1/dc6-submit-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 991))
    doAssert r.approveAs("alice", id) == "collecting"
    doAssert r.approveAs("bob", id) == "executable"
    let fake = submitEvent(id, parents = @[r.messageIds(1)[0]], chainRef = "0x" & "fa".repeat(32))
    r.bob.publish(fake)
    let evs = r.events()
    doAssert intentState(evs, liveDriverFor, id) == "executable",
      policy & ": a submit parented outside the intent moved it to " & intentState(evs, liveDriverFor, id)
    doAssert not reduceActivity(evs, liveDriverFor).anyIt(it.intentId == id and it.kind == "submit"),
      policy & ": the activity feed narrates the fake submit"
    doAssert not logProvenance(evs, liveDriverFor).anyIt(it.intentId == id and it.kind == "submit"),
      policy & ": the provenance lists the fake submit"
    doAssert not reduceFlow(evs, liveDriverFor, @[]).anyIt(it.intentId == id and it.kind == "submit"),
      policy & ": the flow view has information leave at the fake submit"
    verifiesWith(policy & ": a fake submit", r, liveDriverFor, id, 2, "executable")
    echo "6. ", policy, ": a submit parented on a room message is not the intent's settlement on any surface; the audit verifies OK"

  # ── 7. an honest submit, then a fake final parented on a room message ───────────
  block:
    var r = newRoom("/muster/1/dc6-final-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 992))
    doAssert r.approveAs("alice", id) == "collecting"
    doAssert r.approveAs("bob", id) == "executable"
    r.settle(id, final = false)
    r.bob.publish(finalEvent(id, parents = @[r.messageIds(1)[0]], chainRef = ChainRef))
    let evs = r.events()
    doAssert intentState(evs, liveDriverFor, id) == "submitted",
      policy & ": a final parented outside the intent moved it to " & intentState(evs, liveDriverFor, id)
    doAssert not reduceActivity(evs, liveDriverFor).anyIt(it.intentId == id and it.kind == "settled"),
      policy & ": the activity feed narrates the fake final"
    doAssert not logProvenance(evs, liveDriverFor).anyIt(it.intentId == id and it.kind == "final"),
      policy & ": the provenance lists the fake final"
    doAssert not reduceFlow(evs, liveDriverFor, @[]).anyIt(it.intentId == id and it.kind == "final"),
      policy & ": the flow view has information leave at the fake final"
    verifiesWith(policy & ": a fake final", r, liveDriverFor, id, 2, "submitted")
    echo "7. ", policy, ": a final parented on a room message is not the intent's settlement; the audit verifies OK"

echo "audit_record_closed_test: all OK"
