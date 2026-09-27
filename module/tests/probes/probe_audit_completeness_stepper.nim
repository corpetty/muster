## derived-exo-403 s1: the export is one canonical file carrying the effect, its
## materialization, the context, EVERY approval with its grade (committed / unattested
## / rejected) and, when committed, its attestation, the parent-closed lineage its
## provenance names, and the disclosure; every provenance-named position resolves
## inside the file, and every lineage entry is named or an ancestor of a named one.
##
## STEPPER: state = a lifecycle scenario. Each state's verdict, under every live
## policy, builds the room through the hosted path, exports as alice, and checks both
## directions:
##   - every approval in alice's log is in the file, with the grade the fold gives it;
##   - every provenance ref resolves to a lineage entry;
##   - every lineage entry is provenance-named or an ancestor of one — no room
##     messages, declines or other intents padded in.
## Build: see live_room.nim.

import std/sets
import ./audit_room
import ./oracle_emit

const Scenarios = ["proposed", "one_committed", "committed_pasted", "rejected_mix",
                   "declines_messages", "admit_mid", "submitted", "final"]

proc scenarioCorrect(sc: string): bool =
  for policy in LivePolicies:
    var r = newRoom("/muster/1/audit-s1-" & policy & "-" & sc & "/proto")
    let id = r.propose(policy, effectFor(policy, 11))
    discard r.propose(policy, effectFor(policy, 12))          # an unrelated intent
    case sc
    of "one_committed": discard r.approveAs("alice", id)
    of "committed_pasted":
      discard r.approveAs("alice", id); discard r.pasteAs("bob", policy, id)
    of "rejected_mix":
      discard r.approveAs("alice", id); r.misattestAs("bob", policy, id)
    of "declines_messages":
      discard r.approveAs("alice", id)
      r.declineAs("bob", id)
      r.messageAs("alice", 1, "hello room", 1)
    of "admit_mid":
      discard r.approveAs("alice", id)
      discard r.joinCarol()
      discard r.approveAs("bob", id)
    of "submitted", "final":
      discard r.approveAs("alice", id); discard r.approveAs("bob", id)
      r.settle(id, final = sc == "final")
    else: discard
    let evs = r.alice.log.allEvents()
    let res = r.exportAs("alice", id)
    if not res.ok: return false
    let f = res.fileOf()
    if f.field("intent").txt != id: return false
    # 1. every approval, with the fold's grade
    var want = initHashSet[string]()
    for g in approvalGrades(evs, liveDriverFor, id): want.incl g.who & "|" & $g.grade
    var got = initHashSet[string]()
    for (w, g) in f.approvalGradesOf: got.incl w & "|" & g
    if got != want: return false
    # 2. every provenance ref resolves inside the file
    let ids = f.lineageIds()
    var named = initHashSet[string]()
    for e in f.field("provenance").arrOf:
      let ref0 = e.arrOf[1].txt
      if ref0 notin ids: return false
      named.incl ref0
    # 3. every lineage entry is named, or an ancestor of a named entry
    var ancestors = named
    var changed = true
    while changed:
      changed = false
      for e in f.field("lineage").arrOf:
        if e.field("id").txt in ancestors:
          for p in e.field("parents").arrOf:
            if p.txt notin ancestors: (ancestors.incl p.txt; changed = true)
    for k in ids:
      if k notin ancestors: return false
    for k in f.lineageKeys():
      if not k.startsWith("intent/" & id & "/"): return false   # nothing unrelated
  true

proc state(sc: string): JsonNode =
  %*{"stage": sc, "complete_two_way": scenarioCorrect(sc)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "stage", "proposed")
var succ: seq[JsonNode]
for s in Scenarios:
  if s != here: succ.add state(s)
emitSuccessors(succ)

if arg == nil:
  for s in Scenarios:
    doAssert scenarioCorrect(s), "audit file incomplete or padded in scenario " & s
