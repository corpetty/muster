## derived-exo-2dc s2/c2: the core's round count, membership dispatch, and
## finality handling always match exactly what the driver's describe() returns —
## never a hardcoded default.
##
## Randomized descriptors; for each, the core's observable policy must echo
## describe() (field-level), and behaviorally it must take exactly describe().rounds
## rounds of describe().threshold accepted contributions to complete — completing
## early would betray a hardcoded round count. Emits {"matches_describe": ...}.

import ../../src/drivers/driver
import std/random

var r = initRand(0x2DC)
var allMatch = true
for trial in 0 ..< 200:
  let rounds = r.rand(1 .. 4)
  let threshold = r.rand(1 .. 3)
  let membership = [mmAnonymous, mmNamed][r.rand(0 .. 1)]
  let finality = [finImmediate, finProbabilistic, finExternal][r.rand(0 .. 2)]
  let drv = newStubDriver(rounds = rounds, threshold = threshold,
                          membership = membership, finality = finality)
  var col = startCollection(drv)

  var ok = col.roundCount == rounds and
           col.membershipDispatch == membership and
           col.finalityHandling == finality

  # Behavioral: exactly `threshold` accepted per round, `rounds` rounds to close.
  for rnd in 1 .. rounds:
    for k in 1 .. threshold:
      col.submit(drv, Contribution(bytes: @[byte(k and 0xFF)]))
    if rnd < rounds:
      if col.complete or col.round != rnd + 1: ok = false   # completed/advanced wrong
  if not col.complete: ok = false                            # never closed after rounds*threshold

  if not ok: allMatch = false
  echo "{\"matches_describe\": ", (if ok: "true" else: "false"), "}"

doAssert allMatch, "core dispatch diverged from the driver's describe()"
