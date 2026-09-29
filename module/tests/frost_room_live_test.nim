## exo-75c — the room FROST scaffold through the live path: approve it in-app, and audit it.
##
## The scaffold names a contributor "frost:<hex of its Ed25519 key>". Two helpers knew only
## "ed:", "0x", compressed secp keys and "lez:":
##   - verifyAttestation: liveContribute signs an in-app approval and checks its own
##     attestation over P, so every in-app approval of a room-FROST intent was refused as
##     "attestation-mismatch" and nothing was published. The hosted Approve goes there.
##   - the audit's signedBy: no room-FROST audit that carries an approval could verify.
## The FROST tests publish raw contributions, so neither showed.
##   1. both members approve both rounds in-app: each lands, every grade is committed, the
##      card knows who approved, the intent is executable, and its audit verifies;
##   2. a member's own signature made outside muster and pasted in lands unattested, and
##      the audit verifies.
## Build: see probes/live_room.nim (the secp closure + stint + libsodium).

import std/[strutils, sequtils]
import ../src/drivers/frost
import ../src/intents/materialization
import ./probes/audit_room

let frostDrv = newFrostDriver(@[aliceKs.encIdentity().ed, bobKs.encIdentity().ed], 2)
let dFor: DriverFor = proc(kind: string): Driver =
  if kind == "frost": Driver(frostDrv) else: liveDriverFor(kind)

proc proposeFrost(r: Room, n: int): string =
  result = liveProposeIntent(r.alice, aliceKs, dFor, "frost", effectFor("frost", n), int64(Now), uint64(n),
                             account = r.topic, ttlSec = Ttl)
  doAssert result.startsWith("0x"), result

proc auditVerifies(label: string, r: Room, id: string, approvals: int, grade: string) =
  let file = exportAudit(r.alice.log.allEvents(), dFor, id, aliceKs)
  doAssert file.ok, label & ": export refused: " & file.reason
  let v = verifyAudit(file.bytes)
  doAssert v.ok, label & ": the room-FROST audit does not verify: " & v.reason
  doAssert v.approvals.len == approvals and v.approvals.allIt(it.grade == grade),
    label & ": the file's approvals " & $v.approvals.mapIt(it.who & " " & it.grade)

# ── 1. both members, both rounds, in-app ─────────────────────────────────────────
block:
  var r = newRoom("/muster/1/75c-inapp/proto")
  let id = r.proposeFrost(1)
  proc approve(s: CoordinationSession, ks: Keystore): string =
    s.poll()
    liveContribute(s, ks, dFor, id, "", "", bindCtx(), Now)
  doAssert approve(r.alice, aliceKs) == "collecting", "an in-app approval of a room-FROST intent is refused"
  doAssert approve(r.bob, bobKs) == "collecting"
  doAssert reduceIntents(r.events(), dFor)[id].collection.round == 2, "round 1 closed"
  doAssert approve(r.alice, aliceKs) == "collecting"
  doAssert approve(r.bob, bobKs) == "executable"
  let evs = r.events()
  let grades = approvalGrades(evs, dFor, id)
  doAssert grades.len == 4 and grades.allIt(it.grade == agCommitted),
    "every in-app approval commits to P: " & $grades.mapIt(it.who & "/" & $it.round & " " & $it.grade)
  doAssert approvedByMe(evs, id, grades.mapIt(it.who), aliceKs.encIdentity(), myContributorNames(aliceKs)),
    "the card knows Alice approved"
  auditVerifies("in-app", r, id, 4, "committed")
  echo "1. room FROST: both members approve both rounds in-app; committed, executable, and the audit verifies OK"

# ── 2. a signature made outside muster, pasted in ──────────────────────────────────
block:
  var r = newRoom("/muster/1/75c-pasted/proto")
  let id = r.proposeFrost(2)
  let mat = canonicalize(frostDrv, effectFromJson(effectJsonOf(r.events(), id)))
  doAssert liveContribute(r.alice, aliceKs, dFor, id, hexOf(aliceKs.edSign(mat.bytes)), "", bindCtx(), Now) == "collecting"
  let grades = approvalGrades(r.events(), dFor, id)
  doAssert grades.len == 1 and grades[0].grade == agUnattested, $grades.mapIt($it.grade)
  auditVerifies("pasted", r, id, 1, "unattested")
  echo "2. room FROST: a pasted signature lands unattested, and the audit verifies OK"

echo "frost_room_live_test: all OK"
