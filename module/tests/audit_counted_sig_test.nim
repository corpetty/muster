## exo-c00 — the audit file carries the signature the fold counted.
##
## A contribution's key names whoever its publisher wrote, and anyone holding the epoch key
## can publish one. Junk under Alice's name that canonical order puts ahead of her real
## signature took her (who, round) slot wherever a surface picked "the" event under that
## key. The audit export carried the junk as her approval, and verifyAudit then refused the
## whole file: one member could make any intent's audit unverifiable. The file must carry
## the event the fold counted, and verify from its own bytes.
##
## The junk arrives after both approvals, so no carried approval lists it as a parent: an
## approval that links an uncounted event is its own defect (exo-96d), whatever its name.
## Build: see probes/live_room.nim (the secp closure + stint + libsodium).

import std/[strutils, sequtils]
import ./probes/audit_room

for policy in ["threshold", "safe"]:
  var r = newRoom("/muster/1/c00-audit-" & policy & "/proto")
  let id = r.propose(policy, effectFor(policy, 700))
  doAssert r.approveAs("alice", id) == "collecting"
  let realA = sigEventsFor(r.events(), id)[0]
  let who = realA.key.split('/')[3]
  doAssert r.approveAs("bob", id) == "executable"
  # Bob's junk under Alice's name: the same parents, ground until it sorts first.
  var junk: Event
  for i in 0 .. 255:
    junk = contributeEvent(id, who, "0x" & toHex(i, 2).toLowerAscii.repeat(65), parents = realA.parents)
    if eventId(junk) < eventId(realA): break
  doAssert eventId(junk) < eventId(realA), "no junk sorts first"
  r.bob.publish(junk)
  doAssert intentState(r.events(), liveDriverFor, id) == "executable",
    policy & ": junk under Alice's name took her slot in the fold"

  let file = r.exportAs("alice", id)
  doAssert file.ok, policy & ": export refused: " & file.reason
  let v = verifyAudit(file.bytes)
  doAssert v.ok, policy & ": the audit file does not verify: " & v.reason
  doAssert v.approvals.len == 2 and v.approvals.anyIt(it.who == who),
    policy & ": the file's approvals " & $v.approvals.mapIt(it.who)
  echo policy, ": junk under Alice's name sorted first; the audit file carries her real signature and verifies OK"

echo "audit_counted_sig_test: all OK"
