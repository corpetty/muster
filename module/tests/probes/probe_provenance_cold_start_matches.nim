## derived-exo-3a1 s5/c5: the provenance record is rebuildable from log plus keys
## alone, with no side-car audit store — a cold-start replay reproduces exactly the
## record built incrementally. Across randomized input sequences the incrementally
## accumulated record equals a fresh reduction over the same logged inputs. Emits
## {"matches": ...}.
import ../../src/intents/provenance
import std/random

var r = initRand(0x3A15)
let classes = [icPluginBlock, icContribution, icExternalRead, icPeerMessage]
var allMatch = true
for trial in 0 ..< 200:
  let model = [mmAnonymous, mmNamed][r.rand(0 .. 1)]
  var inputs: seq[SignedInput]
  for i in 0 ..< r.rand(1 .. 6):
    inputs.add SignedInput(class: classes[r.rand(0 .. 3)], logPos: i,
      account: "a" & $r.rand(0 .. 3), accountable: true, epoch: 0)
  # Incremental: append an entry as each input arrives.
  var incremental: ProvenanceRecord
  for inp in inputs:
    incremental.entries.add ProvenanceEntry(class: inp.class, logPos: inp.logPos,
      account: (if model == mmNamed: inp.account else: ""))
  # Cold start: rebuild from the logged inputs alone (a reduction, no side-car).
  let rebuilt = buildProvenance(inputs, model)
  let matches = encodeProvenance(incremental) == encodeProvenance(rebuilt)
  if not matches: allMatch = false
  echo "{\"matches\": ", (if matches: "true" else: "false"), "}"
doAssert allMatch, "cold-start provenance did not match the incrementally built record"
