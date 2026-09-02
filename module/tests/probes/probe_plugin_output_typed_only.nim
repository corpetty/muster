## derived-exo-51e s4/c4: a plugin's only output to the host is a typed block; any
## non-typed-block output (raw markup, direct canvas/draw call) is rejected. Across
## a range of outputs the accept/reject decision is correct: typed block with no
## raw payload accepted; anything with raw payload or not-a-typed-block rejected.
## Emits {"rejected_or_typed": ...}.
import ../../src/plugins/plugin
import ./oracle_emit

var obs: seq[JsonNode]

let cases = @[
  PluginOutput(isTypedBlock: true, blk: TypedBlock(kind: bkText, payload: "hi"), raw: ""),
  PluginOutput(isTypedBlock: true, blk: TypedBlock(kind: bkAmount, payload: "100"), raw: ""),
  PluginOutput(isTypedBlock: false, blk: TypedBlock(), raw: "<b>markup</b>"),
  PluginOutput(isTypedBlock: false, blk: TypedBlock(), raw: "canvas.drawRect(...)"),
  PluginOutput(isTypedBlock: true, blk: TypedBlock(kind: bkFact, payload: "x"), raw: "sneaky-raw"),
  PluginOutput(isTypedBlock: false, blk: TypedBlock(), raw: ""),
]

var allCorrect = true
for o in cases:
  let accepted = acceptOutput(o)
  # Correct iff: a clean typed block is accepted, and everything else is rejected.
  let shouldAccept = o.isTypedBlock and o.raw.len == 0
  let correct = accepted == shouldAccept
  if not correct: allCorrect = false
  obs.add flag("rejected_or_typed", correct)

emitTrials(obs)
doAssert allCorrect, "a non-typed-block output was not rejected (or a typed block was)"
