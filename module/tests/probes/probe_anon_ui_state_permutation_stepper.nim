## derived-exo-f60 s1/c1: for an anonymous driver, UI-observable state carries
## only n-of-m slots filled — no field names or distinguishes which member filled
## which slot. Stepper over signer→slot assignments on a fixed contribution set:
## the UI state must equal the baseline at every assignment (identity absent, not
## merely unshown). Emits {"assignment": "...", "ui_state_matches_baseline": ...}.

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/algorithm

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

var perm = @[0, 1, 2, 3]
sort(perm)
let baseline = run(perm)
var allMatch = true
while true:
  let m = run(perm) == baseline
  if not m: allMatch = false
  echo "{\"assignment\": \"", perm, "\", \"ui_state_matches_baseline\": ",
       (if m: "true" else: "false"), "}"
  if not nextPermutation(perm): break

doAssert allMatch, "UI state varied with the signer→slot assignment"
