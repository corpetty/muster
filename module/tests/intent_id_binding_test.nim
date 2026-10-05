## exo-dbd — an intent id is content-addressed, and the fold holds every reader to it.
##
## intentIdFor(effect, policy) is keccak256(effect ++ "|" ++ policy)[:8], so independent
## hosts agree on an id without a round-trip. Only the audit verifier re-checked it. Any
## admitted member could publish a second "intent/<id>/propose" (or "/policy") under an
## honest intent's id: effectJsonOf / intentPolicyOf took the first in ARRIVAL order, and
## an approval signs what they return, while reduceIntents took the first in CANONICAL
## order (the smallest event id, which a publisher can grind). So two members could fold
## different effects for one id, and a card could show one effect while its member signed
## another (invariants 1 and 4).
##
## Carol, a member, publishes substitutes under Alice's honest id, each ground to sort
## ahead of the honest event it imitates: a different effect, a different policy, and the
## honest effect and policy joined by "|" as one propose with no policy (it hashes to the
## same id, but it is not JSON). They reach the room before Alice proposes, and after.
##   1. every member folds the honest effect under the honest policy, Bob's approval signs
##      it and counts, and no surface (the card, the inputs an attestation commits to, the
##      approval's links, the history, both provenance views) names a substitute;
##   2. every delivery order of the same events folds identically, the substitutes first
##      or last, shuffled, duplicated;
##   3. the audit file still exports and verifies;
##   4. a propose under an id that is not its own content address is no intent at all.
## Build: see probes/live_room.nim (the secp closure + stint + libsodium).

import std/[strutils, sequtils, algorithm, random]
import ../src/intents/materialization
import ../src/coordination/audit
import ../src/coordination/room_infra
import ./probes/live_room

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc ground(key, value: string, beat: Event): Event =
  ## An event under `key` carrying `value`, its (absent) parent ground until it sorts
  ## ahead of `beat` in canonical order. Any epoch-key holder chooses an event's parents.
  for i in 0 .. 4095:
    result = Event(parents: @["dbd-" & $i], key: key, value: value)
    if eventId(result) < eventId(beat): return
  doAssert false, "nothing sorts ahead of " & beat.key

const Orphan = "0x" & "de".repeat(8)   ## an id no effect and policy hash to

proc check(evs: seq[Event], id, policy, eH: string, subs: seq[Event], label: string) =
  let want = canonicalize(liveDriverFor(policy), effectFromJson(eH))
  doAssert effectJsonOf(evs, id) == eH, label & ": effectJsonOf read a substitute: " & effectJsonOf(evs, id)
  doAssert intentPolicyOf(evs, id) == policy, label & ": intentPolicyOf read " & intentPolicyOf(evs, id)
  let folded = reduceIntents(evs, liveDriverFor)
  doAssert id in folded, label & ": the honest intent is not folded"
  doAssert folded[id].materialization.bytes == want.bytes, label & ": the fold re-derived a substitute's bytes"
  doAssert Orphan notin folded, label & ": a propose under an id that is not its own was folded"
  let vs = reduceIntentViews(evs, liveDriverFor).filterIt(it.id == id)
  doAssert vs.len == 1 and vs[0].effectJson == eH and vs[0].policy == policy and
           vs[0].txhash == hexOf(want.bytes), label & ": the card shows " & $vs
  doAssert reduceIntentViews(evs, liveDriverFor).allIt(it.id != Orphan), label & ": the orphan has a card"
  let subIds = subs.mapIt(eventId(it))
  let inputs = intentInputs(evs, liveDriverFor, id)
  doAssert inputs.allAccountable, label & ": an input is unaccountable"
  doAssert inputs.allIt(it.logRef notin subIds), label & ": an attestation would commit to a substitute"
  doAssert inputs.filterIt(it.logRef == eventId(proposeEvent(id, eH))).len == 1,
    label & ": the inputs do not cite the honest proposal"
  doAssert approvalParents(evs, liveDriverFor, id).allIt(it notin subIds), label & ": an approval would link a substitute"
  let proposed = reduceActivity(evs, liveDriverFor).filterIt(it.kind == "propose")
  doAssert proposed.len == 1 and proposed[0].intentId == id, label & ": the history tells " & $proposed.len & " proposals"
  let prov = intentProvenance(evs, liveDriverFor, id).filterIt(it.what == "the proposal")
  doAssert prov.len == 1 and prov[0].detail == summarizeEffect(eH), label & ": the provenance names " & $prov
  let lp = logProvenance(evs, liveDriverFor).filterIt(it.kind in ["propose", "policy"])
  doAssert lp.len == 2 and lp.allIt(it.intentId == id), label & ": the room's lineage names " & $lp.mapIt(it.kind & " " & it.intentId)
  for n in roomInfraNeeds(evs, liveDriverFor):
    doAssert n.introducedBy.allIt(it.intentId == id and it.policy == policy), label & ": infra introduced by " & $n.introducedBy

proc summary(evs: seq[Event]): string =
  $reduceIntentViews(evs, liveDriverFor) & $reduceActivity(evs, liveDriverFor) & $logProvenance(evs, liveDriverFor)

var rng = initRand(0xDBD)
for policy in ["safe", "threshold"]:
  for front in [true, false]:
    let label = policy & (if front: ", substitutes first" else: ", substitutes last")
    let topic = "/muster/1/dbd-" & policy & "-" & $front & "/proto"
    var r = newRoom3(topic)
    let other = (if policy == "safe": "threshold" else: "safe")
    let eH = effectFor(policy, 41)
    let id = intentIdFor(eH, policy)
    let joined = eH & "|" & policy
    doAssert intentIdFor(joined) == id, "the joined form hashes to the honest id under no policy"
    let subs = @[ground("intent/" & id & "/propose", effectFor(policy, 999_999), proposeEvent(id, eH)),
                 ground("intent/" & id & "/policy", other, policyDeclEvent(id, policy)),
                 ground("intent/" & id & "/propose", joined, proposeEvent(id, eH)),
                 policyDeclEvent(Orphan, policy), proposeEvent(Orphan, effectFor(policy, 7))]
    if front:
      for e in subs: r.carol.publish(e)
    doAssert liveProposeIntent(r.alice, aliceKs, liveDriverFor, policy, eH, int64(Now), 1,
                               account = (if policy == "safe": SafeAddr else: topic), ttlSec = Ttl) == id
    if not front:
      for e in subs: r.carol.publish(e)
    for s in [r.alice, r.bob, r.carol]: s.poll()

    # ── 1. every member folds the honest intent; Bob signs it, and it counts ──────────
    for (name, s) in [("alice", r.alice), ("bob", r.bob), ("carol", r.carol)]:
      check(s.roomEvents(), id, policy, eH, subs, label & " (" & name & ")")
    doAssert liveContribute(r.bob, bobKs, liveDriverFor, id, "", "", bindCtx(), Now) == "collecting",
      label & ": Bob's approval did not count"
    doAssert liveContribute(r.alice, aliceKs, liveDriverFor, id, "", "", bindCtx(), Now) == "executable",
      label & ": Alice's approval did not complete the intent"
    for (name, s) in [("alice", r.alice), ("bob", r.bob), ("carol", r.carol)]:
      let evs = s.roomEvents()
      check(evs, id, policy, eH, subs, label & " (" & name & ", approved)")
      let v = reduceIntentViews(evs, liveDriverFor).filterIt(it.id == id)[0]
      doAssert v.state == "executable" and v.approvals == 2 and v.committed == 2,
        label & " (" & name & "): " & v.state & " with " & $v.approvals & " approvals, " & $v.committed & " committed"
    echo "1. ", label, ": every member folds the honest effect; both approvals sign it and count; no surface names a substitute OK"

    # ── 2. every delivery order folds identically ──────────────────────────────────
    let all = r.alice.roomEvents()
    let subIds = subs.mapIt(eventId(it))
    let honest = all.filterIt(eventId(it) notin subIds)
    doAssert honest.len + subs.len == all.len
    let base = summary(all)
    var orders = @[("honest first", honest & subs), ("substitutes first", subs & honest),
                   ("reversed", all.reversed)]
    for t in 0 ..< 4:
      var o = all
      for _ in 0 ..< rng.rand(1 .. all.len): o.add all[rng.rand(0 .. all.high)]
      rng.shuffle(o)
      orders.add ("shuffled " & $t, o)
    for (name, evs) in orders:
      check(evs, id, policy, eH, subs, label & " (" & name & ")")
      doAssert summary(evs) == base, label & ": the " & name & " order folds differently"
    echo "2. ", label, ": ", orders.len, " delivery orders fold identically OK"

    # ── 3. the audit file exports and verifies ─────────────────────────────────────
    let file = exportAudit(r.alice.log.allEvents(), liveDriverFor, id, aliceKs)
    doAssert file.ok, label & ": export refused: " & file.reason
    let verdict = verifyAudit(file.bytes)
    doAssert verdict.ok and verdict.approvals.len == 2, label & ": the audit file does not verify: " & verdict.reason
    echo "3. ", label, ": the audit file exports and verifies OK"

# ── 4. an id that is not its propose's content address is no intent ────────────────
block:
  let e = effectFor("threshold", 5)
  for evs in [@[proposeEvent(Orphan, e)], @[policyDeclEvent(Orphan, "threshold"), proposeEvent(Orphan, e)]]:
    doAssert effectJsonOf(evs, Orphan) == "" and intentPolicyOf(evs, Orphan) == "safe"
    doAssert reduceIntents(evs, liveDriverFor).len == 0 and reduceIntentViews(evs, liveDriverFor).len == 0
    doAssert reduceActivity(evs, liveDriverFor).len == 0 and roomInfraNeeds(evs, liveDriverFor).len == 0
  # the same events under the id they hash to are an intent
  let ok = @[policyDeclEvent(intentIdFor(e, "threshold"), "threshold"), proposeEvent(intentIdFor(e, "threshold"), e)]
  doAssert reduceIntents(ok, liveDriverFor).len == 1 and effectJsonOf(ok, intentIdFor(e, "threshold")) == e
  echo "4. a propose under an id that is not its own content address is no intent; under its own it is OK"

echo "intent_id_binding_test: all OK"
