## derived-exo-3a1 s4/c4: under an anonymous membership model the provenance
## record contains no signer identity for any input class; under a named model it
## names the account that actually contributed.
##
## STEPPER (exo-dbc): state is (membership_model, account→input assignment).
## Successors toggle the model or step the assignment by one transposition, so
## BFS from the spec's initial (anonymous, "identity") reaches every combination.

import ../../src/intents/provenance
import ./oracle_emit

let classes = [icPluginBlock, icContribution, icExternalRead]
let accounts = ["alice", "bob", "carol"]

const ModelNames = ["anonymous", "named"]

proc modelOf(name: string): MembershipModel =
  if name == "anonymous": mmAnonymous else: mmNamed

proc inputsFor(assign: seq[int]): seq[SignedInput] =
  for k in 0 ..< 3:
    result.add SignedInput(class: classes[k], logPos: k, account: accounts[assign[k]],
                           accountable: true, epoch: 0)

# Anonymous baseline: the record under the identity assignment. An anonymous
# record must be byte-identical to this at EVERY assignment — identity absent,
# not merely unshown.
let anonBaseline = encodeProvenance(buildProvenance(inputsFor(@[0, 1, 2]), mmAnonymous))

proc disclosureCorrect(modelName: string, assign: seq[int]): bool =
  let model = modelOf(modelName)
  let rec = buildProvenance(inputsFor(assign), model)
  if model == mmAnonymous:
    for e in rec.entries:
      if e.account.len != 0: return false
    return encodeProvenance(rec) == anonBaseline
  for k in 0 ..< 3:
    if rec.entries[k].account != accounts[assign[k]]: return false
  true

proc state(modelName: string, assign: seq[int]): JsonNode =
  %*{"membership_model": modelName, "assignment": permString(assign),
     "identity_disclosure_correct": disclosureCorrect(modelName, assign)}

let arg = oracleStateArg()
let hereModel = oracleStateStr(arg, "membership_model", "anonymous")
let hereAssign = parsePerm(oracleStateStr(arg, "assignment", "identity"), 3)

var succ: seq[JsonNode]
for m in ModelNames:
  if m != hereModel: succ.add state(m, hereAssign)
for q in swapNeighbours(hereAssign): succ.add state(hereModel, q)
emitSuccessors(succ)

if arg == nil:
  for m in ModelNames:
    for q in swapNeighbours(@[0, 1, 2]) & @[@[0, 1, 2]]:
      doAssert disclosureCorrect(m, q),
        "provenance identity disclosure did not follow the membership model"
