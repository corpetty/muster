## derived-exo-403 s6: submit / final entries are included when present, graded as
## external reads with their chain reference, never reported as verified against the
## chain; the file states the stage reached; every pasted approval reads unattested.
##
## STEPPER: state = (stage, approval kind). Stages: proposed, collecting, executable,
## submitted, final, declined; approvals made in-app or pasted. Under every live
## policy (settlement only on the Safe rail) the file's claimed stage equals the
## fold's, settlement entries appear exactly when the log has them, each carries the
## transaction hash, the verifier grades each "external-read", and pasted approvals
## are "unattested" in both the file and the verdict.
## Build: see live_room.nim.

import ./audit_room
import ./oracle_emit

const Stages = ["proposed", "collecting", "executable", "submitted", "final", "declined"]
const Kinds = ["in-app", "pasted"]

proc stageCorrect(stage, kind: string): bool =
  for policy in LivePolicies:
    if stage in ["submitted", "final"] and policy != "safe": continue
    var r = newRoom("/muster/1/audit-s6-" & policy & "-" & stage & "-" & kind & "/proto")
    let id = r.propose(policy, effectFor(policy, 61))
    proc approve(who: string) =
      if kind == "pasted": discard r.pasteAs(who, policy, id) else: discard r.approveAs(who, id)
    case stage
    of "collecting": approve("alice")
    of "executable": (approve("alice"); approve("bob"))
    of "submitted": (approve("alice"); approve("bob"); r.settle(id, final = false))
    of "final": (approve("alice"); approve("bob"); r.settle(id))
    of "declined": r.declineAs("bob", id)
    else: discard
    let evs = r.alice.log.allEvents()
    let res = r.exportAs("alice", id)
    if not res.ok: return false
    let f = res.fileOf()
    if f.field("claims").field("stage").txt != intentState(evs, liveDriverFor, id): return false
    let settlements = f.field("settlement").arrOf
    let wantN = (if stage == "submitted": 1 elif stage == "final": 2 else: 0)
    if settlements.len != wantN: return false
    let v = verifyAudit(res.bytes)
    if not v.ok: return false
    if v.stage != intentState(evs, liveDriverFor, id): return false
    if v.settlement.len != wantN: return false
    for s in v.settlement:
      if s.grade != "external-read" or s.chainRef != ChainRef: return false
    let wantGrade = (if kind == "pasted": "unattested" else: "committed")
    for (_, g) in f.approvalGradesOf:
      if g != wantGrade: return false
    for a in v.approvals:
      if a.grade != wantGrade: return false
  true

proc state(stage, kind: string): JsonNode =
  %*{"stage": stage, "kind": kind, "settlement_graded": stageCorrect(stage, kind)}

let arg = oracleStateArg()
let hs = oracleStateStr(arg, "stage", "proposed")
let hk = oracleStateStr(arg, "kind", "in-app")
var succ: seq[JsonNode]
for s in Stages:
  for k in Kinds:
    if (s, k) != (hs, hk): succ.add state(s, k)
emitSuccessors(succ)

if arg == nil:
  for s in Stages:
    for k in Kinds:
      doAssert stageCorrect(s, k), "settlement/stage grading wrong at " & s & "/" & k
