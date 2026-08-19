## derived-exo-2dc s3/c3: swapping in a different driver (different round count,
## membership model, finality type) requires no core code changes — the core
## adapts purely from describe().
##
## Stepper over distinct driver configurations. The SAME core code (startCollection
## / submit) must adapt to each: its policy echoes the config and it closes in
## exactly that config's round count. No driver-specific branch exists in the core.
## Emits {"driver_config_id": "...", "adapted_correctly": ...}.

import ../../src/drivers/driver

var allAdapted = true
for rounds in [1, 2, 3]:
  for membership in [mmAnonymous, mmNamed]:
    for finality in [finImmediate, finProbabilistic, finExternal]:
      let drv = newStubDriver(rounds = rounds, threshold = 2,
                              membership = membership, finality = finality)
      var col = startCollection(drv)

      var ok = col.roundCount == rounds and
               col.membershipDispatch == membership and
               col.finalityHandling == finality

      for rnd in 1 .. rounds:
        for k in 1 .. 2:
          col.submit(drv, Contribution(bytes: @[1'u8]))
        if rnd < rounds and col.complete: ok = false
      if not col.complete: ok = false

      if not ok: allAdapted = false
      echo "{\"driver_config_id\": \"r", rounds, "-", $membership, "-", $finality,
           "\", \"adapted_correctly\": ", (if ok: "true" else: "false"), "}"

doAssert allAdapted, "core failed to adapt to a swapped driver configuration"
