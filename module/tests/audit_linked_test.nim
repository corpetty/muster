## exo-96d — an approval's links never make its intent's audit file unverifiable.
##
## A live approval is linked to the proposal and to the approvals its signer has seen
## (exo-403), so a later reader can tell when its history reaches events it cannot read,
## and the audit file is parent-closed. But it linked EVERY sig event of the intent. The
## file carries only the approvals the fold counts, so any other contribution an honest
## approval linked (junk under any name, a non-member's signature) left a parent the file
## did not carry. Any epoch-key holder could make any intent's audit unverifiable. And the
## counted event under a key can change: a valid copy of a member's signature that sorts
## ahead of the original becomes the one the file carries, orphaning every link to the
## original.
##   1. junk published before an approval: the approval links only the proposal and the
##      counted approvals, and the file verifies;
##   2. a valid copy of Alice's signature that sorts ahead of the original Bob linked: the
##      file carries the original too (checkably the same approval), and verifies;
##   3. an approval an earlier client made, linked to junk: the export is refused with the
##      reason, never a file its own verifier refuses.
## Build: see probes/live_room.nim (the secp closure + stint + libsodium).

import std/[strutils, sequtils, sets]
import ../src/intents/materialization
import ./probes/audit_room

proc proposeIdsOf(evs: seq[Event], id: string): seq[EventId] =
  for e in evs:
    if e.key == "intent/" & id & "/propose": result.add eventId(e)

proc signedOutside(r: Room, who, policy, id: string): (string, string) =
  ## <who>'s signature over the materialization, made outside muster, and the name the
  ## driver gives it — as audit_room's pasteAs signs, without publishing.
  let ks = ksOf(who)
  let drv = liveDriverFor(policy)
  let ej = effectJsonOf(r.events(), id)
  let mat = canonicalize(drv, effectFromJson(ej))
  var sig = ""
  if policy == "safe":
    var h: array[32, byte]
    for i in 0 ..< 32: h[i] = mat.bytes[i]
    sig = hexOf(ks.sign(h))
  else: sig = hexOf(ks.edSign(mat.bytes))
  (contributorOf(drv, ej, sig), sig)

proc verifies(label: string, r: Room, id: string, approvals: int) =
  let file = r.exportAs("alice", id)
  doAssert file.ok, label & ": export refused: " & file.reason
  let v = verifyAudit(file.bytes)
  doAssert v.ok, label & ": the audit file does not verify: " & v.reason
  doAssert v.approvals.len == approvals, label & ": " & $v.approvals.len & " approvals in the file"

for policy in ["threshold", "safe"]:
  # ── 1. junk before an approval ─────────────────────────────────────────────────
  block:
    var r = newRoom("/muster/1/96d-junk-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 800))
    doAssert r.approveAs("alice", id) == "collecting"
    let junk = contributeEvent(id, "ed:" & "ab".repeat(32), "0x" & "00".repeat(65),
                               parents = proposeIdsOf(r.events(), id))
    r.bob.publish(junk)
    doAssert r.approveAs("bob", id) == "executable"
    let evs = r.events()
    var counted = initHashSet[EventId]()
    for g in approvalGrades(evs, liveDriverFor, id): counted.incl eventId(g.sig)
    let allowed = counted + toHashSet(proposeIdsOf(evs, id))
    for e in evs:
      if eventId(e) in counted:
        for par in e.parents:
          doAssert par in allowed, policy & ": an approval links " & par & ", neither the proposal nor an approval"
    verifies(policy & ": junk before an approval", r, id, 2)
    echo "1. ", policy, ": junk published before an approval is not linked by it; the audit verifies OK"

  # ── 2. a valid copy of Alice's signature sorts ahead of the original ───────────
  block:
    var r = newRoom("/muster/1/96d-copy-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 801))
    doAssert r.approveAs("alice", id) == "collecting"
    doAssert r.approveAs("bob", id) == "executable"
    let evs = r.events()
    let (nameA, _) = r.signedOutside("alice", policy, id)
    var orig: Event
    for e in sigEventsFor(evs, id):
      if e.key.split('/')[3] == nameA: orig = e
    doAssert orig.key.len > 0, policy & ": Alice's approval"
    # the same signature under the same key, parented on a lineage entry (or nothing), until
    # canonical order puts it ahead of the original
    var bases: seq[seq[EventId]] = @[@[]]
    for e in evs:
      if e.key.startsWith("intent/" & id & "/") and e.key.split('/')[2] in ["propose", "policy", "context"]:
        bases.add @[eventId(e)]
    var copy: Event
    var ahead = false
    for ps in bases:
      copy = Event(parents: ps, key: orig.key, value: orig.value)
      if eventId(copy) == eventId(orig): continue
      let order = canonicalOrder(evs & @[copy]).mapIt(eventId(it))
      if order.find(eventId(copy)) < order.find(eventId(orig)): (ahead = true; break)
    doAssert ahead, policy & ": no copy sorts ahead of the original"
    r.bob.publish(copy)
    doAssert intentState(r.events(), liveDriverFor, id) == "executable"
    verifies(policy & ": a copy sorts ahead of the original an approval links", r, id, 2)
    echo "2. ", policy, ": a valid copy sorted ahead of the linked original; the audit carries both and verifies OK"

  # ── 3. an earlier client's approval, linked to junk ─────────────────────────────
  block:
    var r = newRoom("/muster/1/96d-legacy-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 802))
    doAssert r.approveAs("alice", id) == "collecting"
    let junk = contributeEvent(id, "ed:" & "cd".repeat(32), "0x" & "00".repeat(65),
                               parents = proposeIdsOf(r.events(), id))
    r.bob.publish(junk)
    # Bob pastes a signature through a client that linked every sig event of the intent
    let (nameB, sigB) = r.signedOutside("bob", policy, id)
    var parents = proposeIdsOf(r.events(), id)
    for e in sigEventsFor(r.events(), id): parents.add eventId(e)
    r.bob.publish(contributeEvent(id, nameB, sigB, parents = parents))
    doAssert intentState(r.events(), liveDriverFor, id) == "executable"
    let file = r.exportAs("alice", id)
    doAssert not file.ok or verifyAudit(file.bytes).ok,
      policy & ": the export produced a file its own verifier refuses: " & verifyAudit(file.bytes).reason
    doAssert not file.ok and junk.key in file.reason,
      policy & ": the export should name the uncounted link, got ok=" & $file.ok & " " & file.reason
    echo "3. ", policy, ": an approval linked to junk: the export is refused, naming it — never an unverifiable file OK"

echo "audit_linked_test: all OK"
