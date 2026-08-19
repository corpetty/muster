## derived-exo-3a1 s2/c2: every input that reached the signed bytes has an entry
## naming its class and log position, and every entry corresponds to an input that
## actually contributed — two-way. Stepper over effect shapes across the four
## input classes and combinations. Emits {"shape": "...", "coverage_two_way": ...}.
import ../../src/intents/provenance

let classes = [icPluginBlock, icContribution, icExternalRead, icPeerMessage]
var allOk = true
var shape = 0
for count in 1 .. 4:
  for combo in 0 ..< 15:
    if shape >= 60: break
    var inputs: seq[SignedInput]
    var c = combo
    for k in 0 ..< count:
      inputs.add SignedInput(class: classes[c mod 4], logPos: k, account: "a" & $k,
                             accountable: true, epoch: 0)
      c = c div 4
    let rec = buildProvenance(inputs, mmNamed)
    let covers = coverageTwoWay(inputs, rec)
    # Discrimination: a doctored record (an entry that resolves to no input) fails.
    var bad = rec
    bad.entries[0].logPos += 999
    let doctoredFails = not coverageTwoWay(inputs, bad)
    let ok = covers and doctoredFails
    if not ok: allOk = false
    echo "{\"shape\": \"c", count, "-", combo, "\", \"coverage_two_way\": ",
         (if ok: "true" else: "false"), "}"
    inc shape
doAssert allOk, "provenance did not cover the inputs two-way"
