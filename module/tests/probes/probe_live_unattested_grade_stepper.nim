## derived-exo-ef1 s6: a driver-valid signature with no attestation counts toward the
## threshold but is graded unattested in the intent view, provenance, activity, and
## card, never shown as committed; muster itself never produces an unattested approval.
##
## STEPPER: state = (attested, pasted) approvals on one intent, attested + pasted <= 2
## (the threshold). Approvers are alice then bob: the first `attested` approve IN-APP,
## the next `pasted` hand in a signature made outside muster (their key signing the
## materialization directly — what a hardware wallet would produce). Each state's
## verdict, under every live policy:
##   - the fold counts attested + pasted;
##   - every in-app approval has its attestation (muster never emits one without);
##   - every surface grades each approval exactly: the intent view's counts, the card
##     JSON, intentProvenance, logProvenance, and the activity feed.
## Build: see live_room.nim.

import ./live_room
import ./oracle_emit
import ../../src/intents/materialization

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc pastedSig(policy: string, ks: Keystore, evs: seq[Event], id: string): string =
  let mat = canonicalize(liveDriverFor(policy), effectFromJson(effectJsonOf(evs, id)))
  if policy == "safe":
    var h: array[32, byte]
    for i in 0 ..< 32: h[i] = mat.bytes[i]
    hexOf(ks.sign(h))
  else: hexOf(ks.edSign(mat.bytes))

proc mixCorrect(attested, pasted: int): bool =
  for policy in LivePolicies:
    var r = newRoom("/muster/1/ef1-grade-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 8))
    var expectGrade = initTable[string, string]()     # contributor -> grade
    let people = [("alice", aliceKs, r.alice), ("bob", bobKs, r.bob)]
    for k in 0 ..< attested + pasted:
      let (name, ks, sess) = people[k]
      let before = sigEventsFor(r.events(), id).len
      if k < attested:
        discard r.approveAs(name, id)
      else:
        discard liveContribute(sess, ks, liveDriverFor, id,
                               pastedSig(policy, ks, r.events(), id), "", bindCtx(), Now)
      let sigs = sigEventsFor(r.events(), id)
      if sigs.len != before + 1: return false
      # which contributor did that add?
      var who = ""
      for e in sigs:
        let w = e.key.split('/')[3]
        if w notin expectGrade: who = w
      expectGrade[who] = (if k < attested: "committed" else: "unattested")
    let evs = r.events()
    # counted: both kinds count toward the threshold
    if countedApprovals(evs, id) != attested + pasted: return false
    # muster never emits an in-app approval without its attestation
    for who, g in expectGrade:
      var has = false
      for a in attestEventsFor(evs, id):
        if a.key.split('/')[3] == who: has = true
      if (g == "committed") != has: return false
    # the grades, surface by surface
    let grades = approvalGrades(evs, liveDriverFor, id)
    for who, g in expectGrade:
      if $gradeOf(grades, who, 1) != g: return false
    var view: IntentView
    for v in reduceIntentViews(evs, liveDriverFor):
      if v.id == id: view = v
    if view.committed != attested or view.unattested != pasted: return false
    let card = intentViewJson(view, liveDriverFor(policy).describe())
    if card{"committed"}.getInt(-1) != attested or card{"unattested"}.getInt(-1) != pasted:
      return false
    var seenProv = 0
    for it in intentProvenance(evs, liveDriverFor, id):
      if it.cls != icContribution: continue
      inc seenProv
      if it.account notin expectGrade or it.attestation != expectGrade[it.account]: return false
    if seenProv != attested + pasted: return false
    var seenLog = 0
    for it in logProvenance(evs, liveDriverFor):
      if it.kind != "sig" or it.intentId != id: continue
      inc seenLog
      if it.account notin expectGrade or it.attestation != expectGrade[it.account]: return false
    if seenLog != attested + pasted: return false
    var seenAct = 0
    for a in reduceActivity(evs, liveDriverFor):
      if a.kind != "approve" or a.intentId != id: continue
      inc seenAct
      if a.account notin expectGrade or a.attestation != expectGrade[a.account]: return false
    if seenAct != attested + pasted: return false
  true

proc state(a, p: int): JsonNode =
  %*{"attested": a, "pasted": p, "grade_correct": mixCorrect(a, p)}

let arg = oracleStateArg()
let ha = oracleStateInt(arg, "attested", 0)
let hp = oracleStateInt(arg, "pasted", 0)
var succ: seq[JsonNode]
for a in 0 .. 2:
  for p in 0 .. 2 - a:
    if (a, p) != (ha, hp): succ.add state(a, p)
emitSuccessors(succ)

if arg == nil:
  for a in 0 .. 2:
    for p in 0 .. 2 - a:
      doAssert mixCorrect(a, p), "unattested grading wrong at attested=" & $a & " pasted=" & $p
