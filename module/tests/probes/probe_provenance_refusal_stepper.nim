## derived-exo-3a1 s3/c3: signing is refused whenever any input's origin cannot be
## accounted for, and completes when every input can be.
##
## STEPPER (exo-dbc): state is HOW MANY inputs are unaccountable — the dimension
## the spec's `initial` names. Successors are the other counts. Each carries a
## verdict quantified over every (input count, unaccountable subset) that yields
## that many, so a single state stands for the whole family.

import ../../src/intents/provenance
import ./oracle_emit

let classes = [icPluginBlock, icContribution, icExternalRead, icPeerMessage]

proc decisionCorrect(unattributable: int): bool =
  ## Over every arrangement with exactly this many unaccountable inputs, the
  ## sign/refuse decision must track accountability exactly.
  for count in 1 .. 4:
    for mask in 0 ..< (1 shl count):
      var bits = 0
      for k in 0 ..< count:
        if (mask and (1 shl k)) != 0: inc bits
      if bits != unattributable: continue
      var inputs: seq[SignedInput]
      for k in 0 ..< count:
        let unacc = (mask and (1 shl k)) != 0
        inputs.add SignedInput(class: classes[k mod 4], logPos: k, account: "a",
                               accountable: not unacc, epoch: 0)
      let refused = trySign(@[1'u8, 2, 3], inputs, mmNamed) == sdRefused
      if refused != (unattributable > 0): return false
  true

proc state(n: int): JsonNode =
  %*{"unattributable_count": n, "decision_correct": decisionCorrect(n)}

let arg = oracleStateArg()
let here = oracleStateInt(arg, "unattributable_count", 0)
var succ: seq[JsonNode]
for n in 0 .. 4:
  if n != here: succ.add state(n)
emitSuccessors(succ)

if arg == nil:
  for n in 0 .. 4:
    doAssert decisionCorrect(n), "sign/refuse decision did not track input accountability"
