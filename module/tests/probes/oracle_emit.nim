## Emission helpers so probes speak exophial's spec-oracle wire contracts.
##
## The probes measure the invariants correctly, but they used to `echo` one JSON
## object per observation (JSONL). exophial's `spec_oracle._parse_measurement`
## does `json.loads(stdout)` over the WHOLE buffer, so an artifact must emit
## EXACTLY ONE JSON document — every check failed with "artifact stdout is not
## valid JSON: Extra data: line 2 column 1" and no spec had ever graded green
## (exo-dbc). These helpers centralise the three contracts so a probe states its
## observations and never hand-rolls the envelope.
##
## The contracts, from `spec_oracle.py`:
##
## - `property_test` trace form (`_check_trace_invariant`): print
##   `{"traces": [[state, ...], ...]}`. The artifact emits observations only;
##   the runner owns judgment (Daikon atoms + rtamt STL over `trace_invariant`).
## - `model_check` stepper form (`_run_stepper`): the artifact is invoked as
##   `run + [json.dumps(state)]` — the current state as the FINAL argv — and must
##   print `{"successors": [state, ...]}` for THAT state. The runner BFS-walks the
##   reachable graph from the spec's `initial` and asserts `invariant` on every
##   state it reaches, bounded by `max_states`.
## - `metamorphic` (`_check_metamorphic`): print one measurement object; the
##   runner applies the declared `relation_class` to it.
##
## Every probe keeps its `doAssert` — it is what makes the probe fail loudly when
## run by hand, independent of any grader.

import std/[json, os]

# Probes build observations as `JsonNode`, so re-export json rather than make
# every probe import it alongside this module.
export json

proc oracleStateArg*(): JsonNode =
  ## The state the stepper was invoked on: the final argv, parsed. `nil` when the
  ## probe is run by hand with no argument, so a stepper can fall back to its
  ## initial state and stay usable outside the oracle.
  if paramCount() < 1: return nil
  let raw = paramStr(paramCount())
  try: result = parseJson(raw)
  except JsonParsingError: result = nil

proc emitSuccessors*(successors: seq[JsonNode]) =
  ## The `model_check` stepper contract: one document, `successors` a list.
  ## A state with no successors emits an empty list — a terminal state, not an
  ## error; the runner simply has nothing further to enqueue from it.
  echo $(%*{"successors": successors})

proc emitTraces*(traces: seq[seq[JsonNode]]) =
  ## The `property_test` trace contract: one document, `traces` a list of traces,
  ## each a list of observed states.
  var arr = newJArray()
  for t in traces:
    var inner = newJArray()
    for s in t: inner.add s
    arr.add inner
  echo $(%*{"traces": arr})

proc emitTrials*(observations: seq[JsonNode]) =
  ## The common case: N independent randomized trials, each yielding ONE
  ## observation, emitted as ONE trace of N states.
  ##
  ## One trace, not N single-state traces. `trace_monitor` builds rtamt's dataset
  ## as `time = range(len(trace))`, so a one-state trace is a single sample with
  ## no interval and rtamt fails inside its own evaluator
  ## (`UnboundLocalError: ... 'duration' ...`). `always <flag>` over the combined
  ## trace means exactly what it meant per-trial — every trial satisfied the
  ## flag — so nothing is weakened by the grouping.
  emitTraces(@[observations])

proc emitMeasurement*(measurement: JsonNode) =
  ## The `metamorphic` contract: one measurement document for the relation.
  echo $measurement

proc flag*(name: string, value: bool): JsonNode =
  ## One boolean observation, the shape every `kind: flag` atom reads.
  %*{name: value}
