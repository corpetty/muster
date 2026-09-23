## derived-exo-ef1 s1: every approval muster produces IN-APP, under any driver, is
## published with a muster attestation from the same key over P = (context,
## materialization root, provenance record), and changing any input's provenance
## while holding its bytes identical changes P — through the hosted contribute path.
##
## Trials: each live policy × several effects. Per trial, alice approves in-app via
## liveContribute; the observation holds iff (a) exactly one attestation for that
## approval was published and it verifies over the P every member re-derives from the
## log, and (b) re-routing ONE input through a different log event — the same effect
## field value recorded by two different external-read events — changes P while the
## effect bytes stay identical, and the attestation made under one routing does not
## verify under the other. Emits {"attestation_binds": ...} per trial.
## Build: see live_room.nim.

import ./live_room
import ./oracle_emit

var obs: seq[JsonNode]
var allOk = true

for policy in LivePolicies:
  for n in 1 .. 4:
    # (a) the live path attests.
    var r = newRoom("/muster/1/ef1-binds-" & policy & "-" & $n & "/proto")
    let id = r.propose(policy, effectFor(policy, n))
    discard r.approveAs("alice", id)
    let evs = r.events()
    let sigs = sigEventsFor(evs, id)
    let atts = attestEventsFor(evs, id)
    var ok = sigs.len == 1 and atts.len == 1
    if ok:
      let who = sigs[0].key.split('/')[3]
      let p = attestationPayload(evs, liveDriverFor, id)
      ok = p.len > 0 and atts[0].key.split('/')[3] == who and
           verifyAttestation(who, p, atts[0].value)

    # (b) provenance is committed INSIDE P: same effect bytes, the sourced field
    # reached through a different read event (a different content id) → different P.
    let field = (if policy == "safe": "value" else: "text")
    let valueText = (if policy == "safe": $n else: "probe " & $n)
    let sourced = effectFor(policy, n, "\"sources\":{\"" & field & "\":\"read\"}")
    var ra = newRoom("/muster/1/ef1-binds-a-" & policy & "-" & $n & "/proto")
    let ida = ra.propose(policy, sourced)
    ra.alice.publish(readEvent(ida, field, "rpc://node-a", valueText))
    var rb = newRoom("/muster/1/ef1-binds-a-" & policy & "-" & $n & "/proto")
    let idb = rb.propose(policy, sourced)
    rb.alice.publish(readEvent(idb, field, "rpc://node-b", valueText))
    doAssert ida == idb, "same effect bytes -> same intent id"
    let pa = attestationPayload(ra.events(), liveDriverFor, ida)
    let pb = attestationPayload(rb.events(), liveDriverFor, idb)
    ok = ok and pa.len > 0 and pb.len > 0 and pa != pb
    if ok:
      discard ra.approveAs("alice", ida)
      let aa = attestEventsFor(ra.events(), ida)
      ok = aa.len == 1 and not verifyAttestation(aa[0].key.split('/')[3], pb, aa[0].value)

    if not ok: allOk = false
    obs.add flag("attestation_binds", ok)

emitTrials(obs)
doAssert allOk, "a live in-app approval did not carry an attestation binding its provenance"
