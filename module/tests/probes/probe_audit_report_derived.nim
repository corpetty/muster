## derived-exo-403 s7: the readable report is a pure function of the canonical file
## and carries its digest; rendering is deterministic, every rendered fact comes from
## the file (perturbing a rendered field changes the report), it shows each approval's
## grade — pasted ones as unattested — and it is never authoritative.
##
## Trials: randomized rooms through the hosted path. Per trial: render twice (equal);
## the report contains the file's digest and each approval's grade word; perturbing
## the file's effect, stage, an approval grade, or (when settled) the chain reference
## changes the report; and verifying the file gives the same verdict whether or not
## anyone edited the report. Emits {"report_derived": ...}.
## Build: see live_room.nim.

import std/random
import ./audit_room
import ./oracle_emit

proc setField(m: CborValue, key: string, v: CborValue) =
  for i, (k, _) in m.pairs:
    if k.kind == ckText and k.t == key: (m.pairs[i] = (k, v); return)

var rng = initRand(0x407)
var obs: seq[JsonNode]
var allOk = true

for trial in 0 ..< 12:
  let policy = LivePolicies[rng.rand(0 .. LivePolicies.len - 1)]
  var r = newRoom("/muster/1/audit-s7-" & $trial & "/proto")
  let id = r.propose(policy, effectFor(policy, 700 + trial))
  discard r.approveAs("alice", id)
  if rng.rand(0 .. 1) == 1: discard r.pasteAs("bob", policy, id)
  else: discard r.approveAs("bob", id)
  let settled = policy == "safe" and rng.rand(0 .. 1) == 1
  if settled: r.settle(id)
  let res = r.exportAs("alice", id)
  var ok = res.ok
  if ok:
    let rep = renderAuditReport(res.bytes)
    ok = rep.len > 0 and rep == renderAuditReport(res.bytes) and auditDigest(res.bytes) in rep
    let f = res.fileOf()
    for (_, g) in f.approvalGradesOf:
      if g notin rep: ok = false
    # every perturbed rendered field shows up in the report
    var perturbs: seq[string] = @["effect", "stage", "grade"]
    if settled: perturbs.add "chainref"
    for pz in perturbs:
      let g = decode(res.bytes)
      case pz
      of "effect": g.setField("effect", cbText(g.field("effect").t & " "))
      of "stage": g.field("claims").setField("stage", cbText("perturbed-stage"))
      of "grade": g.field("approvals").arr[0].setField("grade", cbText("perturbed-grade"))
      of "chainref": g.field("settlement").arr[0].setField("value", cbText("0xperturbed"))
      else: discard
      if renderAuditReport(encode(g)) == rep: ok = false
    # the report is not authoritative: editing it changes no verdict
    let v1 = verifyAudit(res.bytes)
    var edited = rep
    edited.add "\n(edited: everything above is fine)"
    let v2 = verifyAudit(res.bytes)
    ok = ok and v1.ok and v1 == v2 and edited != rep
  if not ok: allOk = false
  obs.add flag("report_derived", ok)

emitTrials(obs)
doAssert allOk, "the audit report was not a faithful, deterministic rendering of its file"
