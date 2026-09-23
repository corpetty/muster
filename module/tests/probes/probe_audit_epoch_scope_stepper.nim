## derived-exo-403 s5: the file holds only what the exporter can read; when the
## intent's lineage reaches an event the exporter cannot read the export is REFUSED
## with that reason, never truncated; otherwise it succeeds and labels the first epoch
## it covers.
##
## STEPPER: state = when Carol (a non-signer) is admitted, relative to the intent:
##   founder         — alice exports; she read everything (first epoch 0)
##   before_propose  — Carol joins, then the intent runs in front of her
##   after_propose   — Carol joins after the proposal (re-announced to her), before
##                     any approval
##   mid_with_later  — Carol joins after alice's approval; bob approves after, and his
##                     approval links alice's, which Carol cannot read → REFUSED
##   mid_no_later    — Carol joins after alice's approval and nothing follows: nothing
##                     she can read points at it → succeeds, labelled from her epoch
## Under every live policy: the verdict matches, every file entry is in Carol's log,
## no epoch-0 approval leaks into her file, and firstEpoch is her admission epoch.
## Build: see live_room.nim.

import ./audit_room
import ./oracle_emit

const Scenarios = ["founder", "before_propose", "after_propose", "mid_with_later", "mid_no_later"]

proc scenarioCorrect(sc: string): bool =
  for policy in LivePolicies:
    var r = newRoom("/muster/1/audit-s5-" & policy & "-" & sc & "/proto")
    var carol: CoordinationSession = nil
    if sc == "before_propose": carol = r.joinCarol()
    let id = r.propose(policy, effectFor(policy, 51))
    if sc == "after_propose": carol = r.joinCarol()
    discard r.approveAs("alice", id)
    let aliceSig = sigEventsFor(r.events(), id)[0]
    if sc in ["mid_with_later", "mid_no_later"]: carol = r.joinCarol()
    if sc != "mid_no_later": discard r.approveAs("bob", id)
    let exporterKs = (if carol == nil: aliceKs else: carolKs)
    let sess = (if carol == nil: r.alice else: carol)
    sess.poll()
    let evs = sess.log.allEvents()
    let res = exportAudit(evs, liveDriverFor, id, exporterKs)
    if sc == "mid_with_later":
      if res.ok: return false                           # truncation is refused …
      if "read" notin res.reason and "epoch" notin res.reason: return false   # … naming why
      continue
    if not res.ok: return false
    let f = res.fileOf()
    # every lineage entry and approval came from the exporter's own (readable) log
    var have: seq[string]
    for e in evs: have.add eventId(e)
    for i in f.lineageIds():
      if i notin have: return false
    for a in f.field("approvals").arrOf:
      if a.field("sig").field("id").txt notin have: return false
    let wantFirst = (if carol == nil: 0 else: 1)
    if int(f.field("claims").field("firstEpoch").u) != wantFirst: return false
    if carol != nil and sc != "before_propose" and sc != "after_propose":
      for a in f.field("approvals").arrOf:
        if a.field("sig").field("id").txt == eventId(aliceSig): return false
  true

proc state(sc: string): JsonNode =
  %*{"scenario": sc, "scope_correct": scenarioCorrect(sc)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "scenario", "founder")
var succ: seq[JsonNode]
for s in Scenarios:
  if s != here: succ.add state(s)
emitSuccessors(succ)

if arg == nil:
  for s in Scenarios:
    doAssert scenarioCorrect(s), "epoch scoping wrong in scenario " & s
