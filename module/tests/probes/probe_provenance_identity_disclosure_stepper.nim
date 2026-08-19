## derived-exo-3a1 s4/c4: under an anonymous membership model the provenance record
## contains no signer identity for any input class; under a named model it names the
## account that actually contributed. Stepper over membership model × account→input
## assignments: the anonymous record is byte-identical at every assignment (absent,
## not unshown); the named record covaries with the assignment. Emits
## {"membership_model": "...", "identity_disclosure_correct": ...}.
import ../../src/intents/provenance
import std/algorithm

let classes = [icPluginBlock, icContribution, icExternalRead]
let accounts = ["alice", "bob", "carol"]

proc inputsFor(assign: seq[int]): seq[SignedInput] =
  for k in 0 ..< 3:
    result.add SignedInput(class: classes[k], logPos: k, account: accounts[assign[k]],
                           accountable: true, epoch: 0)

# Anonymous baseline: the record under the identity assignment.
let anonBaseline = encodeProvenance(buildProvenance(inputsFor(@[0, 1, 2]), mmAnonymous))

var allCorrect = true
for model in [mmAnonymous, mmNamed]:
  var perm = @[0, 1, 2]
  sort(perm)
  while true:
    let inputs = inputsFor(perm)
    let rec = buildProvenance(inputs, model)
    var correct: bool
    if model == mmAnonymous:
      # No identity anywhere, and the encoded record does not vary with accounts.
      var noIdentity = true
      for e in rec.entries:
        if e.account.len != 0: noIdentity = false
      correct = noIdentity and encodeProvenance(rec) == anonBaseline
    else:
      # Named: each entry names the account that actually contributed.
      correct = true
      for k in 0 ..< 3:
        if rec.entries[k].account != accounts[perm[k]]: correct = false
    if not correct: allCorrect = false
    echo "{\"membership_model\": \"", $model, "\", \"identity_disclosure_correct\": ",
         (if correct: "true" else: "false"), "}"
    if not nextPermutation(perm): break
doAssert allCorrect, "provenance identity disclosure did not follow the membership model"
