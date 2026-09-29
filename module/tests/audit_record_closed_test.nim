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

echo "audit_record_closed_test: all OK"
