## derived-exo-3a1 s2/c2: every input that reached the signed bytes has an entry
## naming its class and log position, and every entry corresponds to an input that
## actually contributed — two-way.
##
## STEPPER (exo-dbc): state is the effect shape, "c<count>-<combo>" over the four
## input classes, with the spec's `initial` id "empty" as the no-input origin.
## Successors are every other shape, so BFS walks the whole family. The shape set
## is sized to stay inside the spec's max_states=60 bound, which the oracle treats
## as a hard failure rather than truncating.

import ../../src/intents/provenance
import std/strutils
import ./oracle_emit

let classes = [icPluginBlock, icContribution, icExternalRead, icPeerMessage]

const MaxCount = 4
const MaxCombo = 14        # 4 counts x 14 combos + "empty" = 57 states (< 60)

proc shapeIds(): seq[string] =
  result.add "empty"
  for count in 1 .. MaxCount:
    for combo in 0 ..< MaxCombo:
      result.add "c" & $count & "-" & $combo

proc inputsFor(id: string): seq[SignedInput] =
  if id == "empty": return @[]
  let body = id[1 .. ^1].split('-')
  doAssert body.len == 2, "malformed shape id: " & id
  let count = parseInt(body[0])
  var c = parseInt(body[1])
  for k in 0 ..< count:
    result.add SignedInput(class: classes[c mod 4], logPos: k, account: "a" & $k,
                           accountable: true, epoch: 0)
    c = c div 4

proc coverageHolds(id: string): bool =
  let inputs = inputsFor(id)
  let rec = buildProvenance(inputs, mmNamed)
  if not coverageTwoWay(inputs, rec): return false
  # Discrimination: a doctored record (an entry resolving to no input) must fail,
  # so a coverageTwoWay stubbed to always agree cannot pass this.
  if rec.entries.len > 0:
    var bad = rec
    bad.entries[0].logPos += 999
    if coverageTwoWay(inputs, bad): return false
  true

proc state(id: string): JsonNode =
  %*{"shape": id, "coverage_two_way": coverageHolds(id)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "shape", "empty")
var succ: seq[JsonNode]
for id in shapeIds():
  if id != here: succ.add state(id)
emitSuccessors(succ)

if arg == nil:
  for id in shapeIds():
    doAssert coverageHolds(id), "provenance did not cover the inputs two-way"
