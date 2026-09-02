## derived-exo-3a1 s1/c1: the encoded signing bytes change when the provenance of
## any input changes, holding the input values byte-identical — provenance is
## committed to inside the signed bytes, not attached alongside. Emits
## {"provenance_binds": ...}.
import ../../src/intents/provenance
import std/random
import ./oracle_emit

var obs: seq[JsonNode]

var r = initRand(0x3A1)
let classes = [icPluginBlock, icContribution, icExternalRead, icPeerMessage]
proc randInputs(r: var Rand, n: int): seq[SignedInput] =
  for i in 0 ..< n:
    result.add SignedInput(class: classes[r.rand(0 .. 3)], logPos: r.rand(0 .. 20),
      account: "a" & $r.rand(0 .. 3), accountable: true, epoch: 0,
      valueBytes: @[byte(r.rand(0 .. 255))])

var allBind = true
for trial in 0 ..< 200:
  let mat = @[byte(r.rand(0 .. 255)), byte(r.rand(0 .. 255))]
  let inputs = randInputs(r, r.rand(1 .. 4))
  let base = signedBytes(mat, buildProvenance(inputs, mmNamed))
  # Change ONE input's provenance (log position or class); its value is untouched.
  var mut = inputs
  let i = r.rand(0 ..< mut.len)
  if r.rand(0 .. 1) == 0: mut[i].logPos = mut[i].logPos + 100
  else: mut[i].class = classes[(ord(mut[i].class) + 1) mod 4]
  let binds = signedBytes(mat, buildProvenance(mut, mmNamed)) != base
  if not binds: allBind = false
  obs.add flag("provenance_binds", binds)

emitTrials(obs)
doAssert allBind, "changing an input's provenance did not change the signed bytes"
