## derived-exo-548 s3/c3: any duplicated or reordered delivery of the same event
## set converges to identical state on every client.
##
## Stepper over the delivery-order space of a fixed event DAG (with a key
## conflict, so ordering actually matters to the reduced value) plus duplication
## variants. Every reachable delivery state must reduce to the same canonical
## state digest as the in-order, no-duplicate reference. Emits
## {"delivery_state_id": "...", "converged": ...} per explored state.

import ../../src/log/log
import std/algorithm

# A small DAG. e2 and e0 both write key "a" — the causal order (e0 before e2,
# via the parent edge) decides the winner deterministically, so a client that
# ordered by arrival instead of causally would diverge and fail.
let e0 = Event(parents: @[], key: "a", value: "1")
let id0 = eventId(e0)
let e1 = Event(parents: @[id0], key: "b", value: "2")
let id1 = eventId(e1)
let e2 = Event(parents: @[id0], key: "a", value: "3")
let id2 = eventId(e2)
let e3 = Event(parents: @[id1, id2], key: "b", value: "4")

let events = @[e0, e1, e2, e3]
let reference = stateDigest(reduce(events))

proc digestForDelivery(order: seq[int], dupIndex: int): string =
  var log: Log
  for i in order:
    log.ingest(events[i])
    if i == dupIndex: log.ingest(events[i])   # duplicate this one on arrival
  stateDigest(log.state())

var allConverged = true
var explored = 0
var perm = @[0, 1, 2, 3]
sort(perm)
block outer:
  while true:
    # For each permutation: no duplication, then duplicate each position once.
    for dup in @[-1, 0, 1, 2, 3]:
      let got = digestForDelivery(perm, (if dup < 0: -1 else: perm[dup]))
      let converged = got == reference
      if not converged: allConverged = false
      echo "{\"delivery_state_id\": \"", perm, "+dup", dup,
           "\", \"converged\": ", (if converged: "true" else: "false"), "}"
      inc explored
      if explored >= 150: break outer
    if not nextPermutation(perm): break

doAssert allConverged, "a delivery order/duplication diverged from the canonical state"
