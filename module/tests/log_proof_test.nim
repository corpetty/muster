## Log proofs (M4, exo-002.4): a proof verifies iff the log is unchanged — any
## tamper (a value, a key, a parent link, the order, a dropped middle event, the
## digest) is REFUSED with a named reason; the proof is a pure function of the event
## set; the JSON form round-trips. Pure Nim.

import std/[json, algorithm, strutils]
import ../src/log/proof

let a = Event(key: "intent/x/propose", value: "{\"to\":\"0xabc\",\"value\":5}")
let b = Event(parents: @[eventId(a)], key: "intent/x/sig/A/1", value: "sigA")
let c = Event(parents: @[eventId(b)], key: "intent/x/sig/B/1", value: "sigB")
let m = Event(key: "message/1", value: "{\"author\":\"alice\",\"body\":\"hi\"}")
let events = @[a, b, c, m]

# ── 1. builds, verifies, and is a pure function of the SET ───────────────────────
block:
  let p = buildProof(events, 0, 1)
  doAssert p.verifyProof().ok, p.verifyProof().reason
  var shuffled = events.reversed()
  shuffled.add b   # duplicate
  let q = buildProof(shuffled, 0, 1)
  doAssert q.ids == p.ids and q.digest == p.digest and q.proofDigest() == p.proofDigest()
  echo "1. a proof verifies and is identical under reorder + duplication (inv 4) OK"

# ── 2. every tamper is refused, each with its reason ────────────────────────────
block:
  let p = buildProof(events, 0, 1)
  var t = p; t.events[2].value = "sigX"
  doAssert not t.verifyProof().ok and "does not match its claimed id" in t.verifyProof().reason
  t = p; t.events[0].key = "intent/y/propose"
  doAssert not t.verifyProof().ok
  t = p; t.events[2].parents = @[]
  doAssert not t.verifyProof().ok, "changing a parent changes the id → refused"
  t = p; t.digest = "00"
  doAssert not t.verifyProof().ok and "digest" in t.verifyProof().reason
  # drop the middle of the chain (b) but keep c, which names b as a parent
  var dropped: seq[Event]
  for e in p.events:
    if e.key != b.key: dropped.add e
  t = buildProof(dropped, 0, 1)
  doAssert not t.verifyProof().ok and "parent-closed" in t.verifyProof().reason
  # re-sequence: swap two events but keep their claimed ids aligned to the swap
  t = p
  swap(t.events[0], t.events[3]); swap(t.ids[0], t.ids[3])
  doAssert not t.verifyProof().ok and "canonical order" in t.verifyProof().reason
  t = p; t.epochFrom = 3; t.epochTo = 1
  doAssert not t.verifyProof().ok and "epoch" in t.verifyProof().reason
  echo "2. value / key / parent / digest / dropped-middle / re-sequenced / epoch tampers all REFUSED OK"

# ── 3. JSON round-trip preserves verifiability; a foreign format is not a proof ─
block:
  let p = buildProof(events, 2, 2)
  let j = p.toJson()
  doAssert j["format"].getStr() == "muster.log-proof.v1" and j["proofDigest"].getStr() == p.proofDigest()
  let back = proofFromJson(j)
  doAssert back.verifyProof().ok and back.proofDigest() == p.proofDigest()
  var refused = false
  try: discard proofFromJson(%*{"format": "something-else"})
  except ValueError: refused = true
  doAssert refused
  echo "3. JSON round-trip verifies; a foreign format raises OK"

echo "log_proof_test: all OK"
