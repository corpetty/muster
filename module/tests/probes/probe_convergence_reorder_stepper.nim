## derived-exo-548 s3/c3: any duplicated or reordered delivery of the same event
## set converges to identical state on every client.
##
## STEPPER (exo-dbc): state is "<order>+dup<n>" over the delivery-order space of
## a fixed event DAG (carrying a key conflict, so ordering genuinely matters to
## the reduced value) crossed with which arrival is duplicated. Successors step
## the order by one transposition or change which event is duplicated. The spec\'s
## initial id "in_order_no_dup" is the identity order with no duplication.

import ../../src/log/log
import std/algorithm
import std/strutils
import ./oracle_emit

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

const InOrderNoDup = "0123+dup-1"

proc stateId(perm: seq[int], dup: int): string = permString(perm) & "+dup" & $dup

proc convergedAt(perm: seq[int], dup: int): bool =
  digestForDelivery(perm, (if dup < 0: -1 else: perm[dup])) == reference

proc state(perm: seq[int], dup: int): JsonNode =
  %*{"delivery_state_id": stateId(perm, dup), "converged": convergedAt(perm, dup)}

proc parseState(id: string): (seq[int], int) =
  if id == "in_order_no_dup": return (@[0, 1, 2, 3], -1)
  let p = id.split("+dup")
  doAssert p.len == 2, "malformed delivery_state_id: " & id
  (parsePerm(p[0], 4), parseInt(p[1]))

let arg = oracleStateArg()
let (herePerm, hereDup) = parseState(oracleStateStr(arg, "delivery_state_id", "in_order_no_dup"))

var succ: seq[JsonNode]
for q in swapNeighbours(herePerm): succ.add state(q, hereDup)
for d in [-1, 0, 1, 2, 3]:
  if d != hereDup: succ.add state(herePerm, d)
emitSuccessors(succ)

if arg == nil:
  var perm = @[0, 1, 2, 3]
  sort(perm)
  while true:
    for dup in [-1, 0, 1, 2, 3]:
      doAssert convergedAt(perm, dup),
        "a delivery order/duplication diverged from the canonical state"
    if not nextPermutation(perm): break
