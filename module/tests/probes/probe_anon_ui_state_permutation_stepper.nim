## derived-exo-f60 s1/c1: for an anonymous driver, UI-observable state carries
## only n-of-m slots filled — no field names or distinguishes which member filled
## which slot. Stepper over signer→slot assignments on a fixed contribution set:
## the UI state must equal the baseline at every assignment (identity absent, not
## merely unshown). STEPPER (exo-dbc): state is the signer→slot assignment; successors are the
## assignments one transposition away, so BFS from the identity ("identity" in
## the spec's initial) reaches every permutation.

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/algorithm
import ./oracle_emit

proc uiRepr(co: AnonCoordination): string =
  result = $co.state.filled & "/" & $co.state.total & ":"
  for c in co.state.contributions:
    for b in c: result.add $b & ","
    result.add "|"

let contribs = @[@[1'u8, 2], @[3'u8], @[9'u8, 9, 9], @[0'u8]]
let signers = @["alice", "bob", "carol", "dave"]

proc run(assignment: seq[int]): string =
  var co = newAnonCoordination(total = contribs.len)
  for i in 0 ..< contribs.len:
    co.ingest(Arrival(contribution: Contribution(bytes: contribs[i]),
                      signer: signers[assignment[i]]))
  uiRepr(co)

let baseline = run(@[0, 1, 2, 3])

proc state(p: seq[int]): JsonNode =
  %*{"assignment": permString(p), "ui_state_matches_baseline": run(p) == baseline}

let here = parsePerm(oracleStateStr(oracleStateArg(), "assignment", "identity"), contribs.len)
var succ: seq[JsonNode]
for q in swapNeighbours(here): succ.add state(q)
emitSuccessors(succ)

if oracleStateArg() == nil:
  var perm = @[0, 1, 2, 3]
  sort(perm)
  while true:
    doAssert run(perm) == baseline, "UI state varied with the signer→slot assignment"
    if not nextPermutation(perm): break
