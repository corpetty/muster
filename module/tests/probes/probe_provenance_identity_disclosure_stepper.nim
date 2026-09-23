## derived-exo-3a1 s4/c4: the provenance record names the account that actually
## contributed each input (every driver is named — anonymous membership was retired,
## ADR-015; the record stays confined to the room's epoch, s6).
##
## STEPPER (exo-dbc): state is the account→input assignment. Successors step it by
## one transposition, so BFS from the spec's initial ("identity") reaches every
## permutation. At each, the record must covary EXACTLY with the assignment — the
## recorded account is the one that contributed, never an arbitrary or stale value.

import ../../src/intents/provenance
import ./oracle_emit

let classes = [icPluginBlock, icContribution, icExternalRead]
let accounts = ["alice", "bob", "carol"]

proc inputsFor(assign: seq[int]): seq[SignedInput] =
  for k in 0 ..< 3:
    result.add SignedInput(class: classes[k], logPos: k, account: accounts[assign[k]],
                           accountable: true, epoch: 0)

proc disclosureCorrect(assign: seq[int]): bool =
  let rec = buildProvenance(inputsFor(assign))
  for k in 0 ..< 3:
    if rec.entries[k].account != accounts[assign[k]]: return false
  true

proc state(assign: seq[int]): JsonNode =
  %*{"assignment": permString(assign),
     "identity_disclosure_correct": disclosureCorrect(assign)}

let arg = oracleStateArg()
let hereAssign = parsePerm(oracleStateStr(arg, "assignment", "identity"), 3)

var succ: seq[JsonNode]
for q in swapNeighbours(hereAssign): succ.add state(q)
emitSuccessors(succ)

if arg == nil:
  for q in swapNeighbours(@[0, 1, 2]) & @[@[0, 1, 2]]:
    doAssert disclosureCorrect(q),
      "provenance record did not name the account that contributed"
