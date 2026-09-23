## derived-exo-403 s4: the names in both the canonical file and the readable report
## are exactly the accounts that contributed — no missing, extra, or swapped signer.
##
## STEPPER: state = who approved: "identity" (alice), "bob", or "both" — each covering
## committed and pasted approvals. Under every live policy the file's approvals must
## name exactly the contributors the fold recognises, and the report's Approvals
## section must name each of them while naming no member who did not approve.
## Catches a file or report that drops, invents, or swaps a signer.
## Build: see live_room.nim.

import std/sets
import ./audit_room
import ./oracle_emit

const Assignments = ["identity", "bob", "both"]

proc idOf(policy, who: string): string =
  let ks = ksOf(who)
  if policy == "safe": hexOf(ks.address()).toLowerAscii
  else: "ed:" & hexOf(ks.encIdentity().ed)[2 .. ^1]

proc namesCorrect(assignment: string): bool =
  let approvers = (case assignment
    of "bob": @["bob"]
    of "both": @["alice", "bob"]
    else: @["alice"])
  for policy in LivePolicies:
    for pasteFirst in [false, true]:
      var r = newRoom("/muster/1/audit-s4-" & policy & "-" & assignment & "/proto")
      let id = r.propose(policy, effectFor(policy, 41))
      for k, who in approvers:
        if pasteFirst and k == 0: discard r.pasteAs(who, policy, id)
        else: discard r.approveAs(who, id)
      let res = r.exportAs("alice", id)
      if not res.ok: return false
      var want, got = initHashSet[string]()
      for who in approvers: want.incl idOf(policy, who)
      for (w, _) in res.fileOf().approvalGradesOf: got.incl w.toLowerAscii
      if got != want: return false
      # the report's signers are its Approvals section (it also names its exporter,
      # which is not a claim about who signed)
      let full = renderAuditReport(res.bytes).toLowerAscii
      let i0 = full.find("## approvals")
      if i0 < 0: return false
      let i1 = full.find("\n## ", i0 + 3)
      let report = full[i0 ..< (if i1 < 0: full.len else: i1)]
      for who in ["alice", "bob"]:
        let named = idOf(policy, who) in report
        if named != (who in approvers): return false
  true

proc state(a: string): JsonNode =
  %*{"assignment": a, "names_correct": namesCorrect(a)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "assignment", "identity")
var succ: seq[JsonNode]
for a in Assignments:
  if a != here: succ.add state(a)
emitSuccessors(succ)

if arg == nil:
  for a in Assignments:
    doAssert namesCorrect(a), "audit names wrong for assignment " & a
