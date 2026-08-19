## derived-exo-3a1 s3/c3: signing is refused whenever any input's origin cannot be
## accounted for, and completes when every input can be. Stepper over which inputs
## are unaccountable (every subset) crossed with the input classes. Emits
## {"unattributable": n, "decision_correct": ...}.
import ../../src/intents/provenance

let classes = [icPluginBlock, icContribution, icExternalRead, icPeerMessage]
var allCorrect = true
var states = 0
for count in 1 .. 4:
  for mask in 0 ..< (1 shl count):
    if states >= 60: break
    var inputs: seq[SignedInput]
    var anyUnacc = false
    for k in 0 ..< count:
      let unacc = (mask and (1 shl k)) != 0
      if unacc: anyUnacc = true
      inputs.add SignedInput(class: classes[k mod 4], logPos: k, account: "a",
                             accountable: not unacc, epoch: 0)
    let refused = trySign(@[1'u8, 2, 3], inputs, mmNamed) == sdRefused
    let correct = refused == anyUnacc
    if not correct: allCorrect = false
    var unattr = 0
    for k in 0 ..< count:
      if (mask and (1 shl k)) != 0: inc unattr
    echo "{\"unattributable\": ", unattr, ", \"decision_correct\": ",
         (if correct: "true" else: "false"), "}"
    inc states
doAssert allCorrect, "sign/refuse decision did not track input accountability"
