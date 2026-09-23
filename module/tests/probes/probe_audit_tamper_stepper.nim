## derived-exo-403 s2: a pure verifier given only the file re-derives everything it
## can and checks the exporter's signature over what it can't; the untouched file is
## accepted — its pasted approvals reported unattested — and any single change is
## refused with a named discrepancy.
##
## STEPPER: state = a mutation. From a valid file (a Safe intent and a threshold
## intent, each with a committed and a pasted approval; the Safe one settled), each
## mutation edits ONE field class of the decoded file and re-encodes it canonically —
## so it is a well-formed file that only lies — and the verifier must refuse it with a
## reason; "none" must verify, reporting the pasted approval unattested. The verifier
## is handed bytes only: no log, no keys, no network.
## Build: see live_room.nim.

import ./audit_room
import ./oracle_emit

const Mutations = ["none", "effect", "materialization", "context_environment",
  "context_expiry", "sig_bytes", "attest_bytes", "grade_up", "grade_down",
  "strip_attest", "swap_attest", "provenance_class", "provenance_ref",
  "lineage_value", "drop_lineage", "reorder_lineage", "sig_other_intent",
  "splice_other_room", "claims_threshold", "claims_stage", "claims_disclosure",
  "issuer_signature", "raw_byte_flip"]

proc setField(m: CborValue, key: string, v: CborValue) =
  for i, (k, _) in m.pairs:
    if k.kind == ckText and k.t == key: (m.pairs[i] = (k, v); return)
  m.pairs.add (cbText(key), v)

proc flipText(v: CborValue): CborValue =
  var t = v.t
  t[^1] = (if t[^1] == 'a': 'b' else: 'a')
  cbText(t)

proc flipBytes(v: CborValue): CborValue =
  var b = v.b
  b[b.len div 2] = b[b.len div 2] xor 0x01
  cbBytes(b)

type Fixture = object
  files: seq[seq[byte]]     ## one valid file per policy
  otherSig: seq[string]     ## a valid signature on ANOTHER intent, per policy
  otherLineage: seq[CborValue]  ## a lineage entry from ANOTHER room, per policy

proc buildFixture(): Fixture =
  for policy in LivePolicies:
    var r = newRoom("/muster/1/audit-s2-" & policy & "/proto")
    let id = r.propose(policy, effectFor(policy, 21))
    discard r.approveAs("alice", id)
    discard r.pasteAs("bob", policy, id)
    if policy == "safe": r.settle(id)
    let res = r.exportAs("alice", id)
    result.files.add res.bytes
    let id2 = r.propose(policy, effectFor(policy, 22))
    discard r.approveAs("alice", id2)
    result.otherSig.add sigEventsFor(r.events(), id2)[0].value
    var r2 = newRoom("/muster/1/audit-s2-elsewhere-" & policy & "/proto")
    let id3 = r2.propose(policy, effectFor(policy, 23))
    discard r2.approveAs("alice", id3)
    let res3 = r2.exportAs("alice", id3)
    result.otherLineage.add (if res3.ok: res3.fileOf().field("lineage").arrOf[0] else: nil)

proc mutate(file: seq[byte], m: string, other: string, foreign: CborValue): seq[byte] =
  if m == "raw_byte_flip":
    result = file
    result[result.len div 3] = result[result.len div 3] xor 0x40
    return
  let f = decode(file)
  let apps = f.field("approvals").arrOf
  var committed, pasted: CborValue
  for a in apps:
    if a.field("grade").txt == "committed": committed = a
    elif a.field("grade").txt == "unattested": pasted = a
  case m
  of "effect": f.setField("effect", flipText(f.field("effect")))
  of "materialization": f.setField("materialization", flipBytes(f.field("materialization")))
  of "context_environment":
    let c = f.field("context"); c.setField("environment", flipText(c.field("environment")))
  of "context_expiry":
    let c = f.field("context"); c.setField("expiry", cbUint(c.field("expiry").u + 1))
  of "sig_bytes":
    let s = committed.field("sig"); s.setField("value", flipText(s.field("value")))
  of "attest_bytes":
    let a = committed.field("attests").arrOf[0]; a.setField("value", flipText(a.field("value")))
  of "grade_up": pasted.setField("grade", cbText("committed"))
  of "grade_down": committed.setField("grade", cbText("unattested"))
  of "strip_attest": committed.setField("attests", cbArray(@[]))
  of "swap_attest":
    let a = committed.field("attests").arrOf[0]
    pasted.setField("attests", cbArray(@[a]))
    committed.setField("attests", cbArray(@[]))
  of "provenance_class":
    let e = f.field("provenance").arrOf[0]
    e.arr[0] = cbText(if e.arr[0].t == "peer-message": "external-read" else: "peer-message")
  of "provenance_ref":
    let e = f.field("provenance").arrOf[0]; e.arr[1] = flipText(e.arr[1])
  of "lineage_value":
    let e = f.field("lineage").arrOf[0]; e.setField("value", flipText(e.field("value")))
  of "drop_lineage":
    let l = f.field("lineage"); l.arr.delete(l.arr.high)
  of "reorder_lineage":
    let l = f.field("lineage")
    if l.arr.len >= 2: swap(l.arr[0], l.arr[^1])
  of "sig_other_intent":
    let s = committed.field("sig"); s.setField("value", cbText(other))
  of "splice_other_room":
    if foreign != nil: f.field("lineage").arr.add foreign
  of "claims_threshold":
    let c = f.field("claims"); c.setField("threshold", cbUint(c.field("threshold").u + 1))
  of "claims_stage":
    let c = f.field("claims")
    c.setField("stage", cbText(if c.field("stage").txt == "final": "collecting" else: "final"))
  of "claims_disclosure":
    let c = f.field("claims"); c.field("disclosure").arr.delete(0)
  of "issuer_signature": f.setField("signature", flipBytes(f.field("signature")))
  else: discard
  encode(f)

let fx = buildFixture()

proc verdictCorrect(m: string): bool =
  for i, policy in LivePolicies:
    if fx.files[i].len == 0: return false               # export must succeed at all
    let v = verifyAudit(mutate(fx.files[i], m, fx.otherSig[i], fx.otherLineage[i]))
    if m == "none":
      if not v.ok: return false
      var sawPasted, sawCommitted = false
      for a in v.approvals:
        if a.grade == "unattested": sawPasted = true
        if a.grade == "committed": sawCommitted = true
      if not (sawPasted and sawCommitted): return false
    else:
      if v.ok or v.reason.len == 0: return false
  true

proc state(m: string): JsonNode =
  %*{"mutation": m, "verdict_correct": verdictCorrect(m)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "mutation", "none")
var succ: seq[JsonNode]
for m in Mutations:
  if m != here: succ.add state(m)
emitSuccessors(succ)

if arg == nil:
  for m in Mutations:
    doAssert verdictCorrect(m), "verifier mis-graded the '" & m & "' mutation"
