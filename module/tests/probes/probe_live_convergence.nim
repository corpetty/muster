## derived-exo-ef1 s8: attestations are log events — two instances with the same
## event set, in any order and with duplicates, reach identical counts and grades,
## with no side-car store.
##
## Trials: randomized rooms mixing in-app (attested), pasted (unattested) and forged
## (bogus attestation) approvals across the live policies, built through the hosted
## path. Per trial the event set is folded (a) as published, (b) shuffled with
## duplicates by a second "instance", and (c) replayed cold into a fresh Log one event
## at a time — and the counts, every approval's grade, and the intent views
## (committed / unattested) must be identical in all three. A room that attested
## nothing is not a vacuous pass: a trial holds only if its attested approvals are
## actually graded committed. Emits {"converges": ...} per trial.
## Build: see live_room.nim.

import std/random
import ./live_room
import ./oracle_emit
import ../../src/intents/materialization

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc summary(evs: seq[Event], ids: seq[string]): string =
  for id in ids:
    result.add id & ":" & $countedApprovals(evs, id) & ":" & $approvalGrades(evs, liveDriverFor, id)
  for v in reduceIntentViews(evs, liveDriverFor):
    result.add "|" & v.id & ":" & v.state & ":" & $v.committed & ":" & $v.unattested

var rng = initRand(0xEF1)
var obs: seq[JsonNode]
var allOk = true

for trial in 0 ..< 24:
  let policy = LivePolicies[rng.rand(0 .. LivePolicies.len - 1)]
  var r = newRoom("/muster/1/ef1-conv-" & $trial & "/proto")
  var ids: seq[string]
  var expectCommitted = 0
  for k in 0 ..< rng.rand(1 .. 2):
    let id = r.propose(policy, effectFor(policy, 100 * trial + k))
    ids.add id
    for (name, ks, sess) in [("alice", aliceKs, r.alice), ("bob", bobKs, r.bob)]:
      case rng.rand(0 .. 3)
      of 0: discard                                     # abstains
      of 1:                                             # in-app → attested
        discard r.approveAs(name, id)
        inc expectCommitted
      of 2:                                             # pasted → unattested
        let mat = canonicalize(liveDriverFor(policy), effectFromJson(effectJsonOf(r.events(), id)))
        var sig = ""
        if policy == "safe":
          var h: array[32, byte]
          for i in 0 ..< 32: h[i] = mat.bytes[i]
          sig = hexOf(ks.sign(h))
        else: sig = hexOf(ks.edSign(mat.bytes))
        discard liveContribute(sess, ks, liveDriverFor, id, sig, "", bindCtx(), Now)
      else:                                             # in-app, then a forged extra attestation
        discard r.approveAs(name, id)
        inc expectCommitted
        let who = sigEventsFor(r.events(), id)[^1].key.split('/')[3]
        sess.publish(attestEvent(id, who, 1, "0x" & "ab".repeat(65)))
  let evs = r.events()
  let a = summary(evs, ids)
  # (b) another instance: shuffled, with duplicates
  var other = evs
  for _ in 0 ..< rng.rand(1 .. evs.len): other.add evs[rng.rand(0 .. evs.high)]
  rng.shuffle(other)
  let b = summary(other, ids)
  # (c) cold start: ingest one by one into a fresh log, fold from the log alone
  var cold: Log
  for e in other: cold.ingest(e)
  let c = summary(cold.allEvents(), ids)
  var committed = 0
  for id in ids:
    for g in approvalGrades(evs, liveDriverFor, id):
      if g.grade == agCommitted: inc committed
  let ok = a == b and b == c and committed == expectCommitted
  if not ok: allOk = false
  obs.add flag("converges", ok)

emitTrials(obs)
doAssert allOk, "attested/unattested grading did not converge across order, duplication, and cold start"
