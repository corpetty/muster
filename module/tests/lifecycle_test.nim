## Intent lifecycle engine test (FURPS F-3). Exercises the full state machine and
## the state = reduce(log) property, over the stub driver.

import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/intents/materialization
import ../src/intents/signing_payload
import ../src/intents/lifecycle

let effect = Effect(schemaId: "muster.effect.transfer.v1",
                    fields: @[("amount", cbUint(100'u64)), ("to", cbText("alice"))])
let ctx = SigningContext(environment: "test", account: "acct", slot: "0", expiry: 1000'u64)

block happyPath:
  # 2 rounds of 2 accepted contributions each → executable, then submit → final.
  let drv = newStubDriver(rounds = 2, threshold = 2)
  var it = newIntent(drv, effect, ctx)
  doAssert it.state == lsDraft
  it.apply(drv, IntentEvent(kind: iePropose, now: 0))
  doAssert it.state == lsProposed
  for k in 1 .. 4:
    it.apply(drv, IntentEvent(kind: ieContribute, now: 1,
                              contribution: Contribution(bytes: @[byte(k)])))
  doAssert it.state == lsExecutable, $it.state
  it.apply(drv, IntentEvent(kind: ieSubmit, now: 2))
  doAssert it.state == lsSubmitted
  it.apply(drv, IntentEvent(kind: ieSettling, now: 3))
  doAssert it.state == lsSettling
  it.apply(drv, IntentEvent(kind: ieFinal, now: 4))
  doAssert it.state == lsFinal
  echo "happy path draft->proposed->collecting->executable->submitted->settling->final: OK"

block expiry:
  let drv = newStubDriver()
  var it = newIntent(drv, effect, ctx)   # expiry 1000
  it.apply(drv, IntentEvent(kind: iePropose, now: 1001))   # past expiry pre-empts
  doAssert it.state == lsExpired
  echo "expiry: past-expiry -> expired: OK"

block drop:
  let drv = newStubDriver()
  var it = newIntent(drv, effect, ctx)
  it.apply(drv, IntentEvent(kind: iePropose, now: 0))
  it.apply(drv, IntentEvent(kind: ieDrop, now: 1))
  doAssert it.state == lsDropped
  echo "drop: -> dropped: OK"

block reorgReturnsToSettling:   # R-8
  let drv = newStubDriver(rounds = 1, threshold = 1)
  var it = newIntent(drv, effect, ctx)
  it.apply(drv, IntentEvent(kind: iePropose, now: 0))
  it.apply(drv, IntentEvent(kind: ieContribute, now: 0))
  doAssert it.state == lsExecutable
  it.apply(drv, IntentEvent(kind: ieSubmit, now: 1))
  it.apply(drv, IntentEvent(kind: ieFinal, now: 2))
  doAssert it.state == lsFinal
  it.apply(drv, IntentEvent(kind: ieReorg, now: 3))
  doAssert it.state == lsSettling
  echo "reorg: final -> settling (R-8): OK"

block stateIsReduceOfLog:
  let drv = newStubDriver(rounds = 2, threshold = 2)
  let events = @[
    IntentEvent(kind: iePropose, now: 0),
    IntentEvent(kind: ieContribute, now: 1), IntentEvent(kind: ieContribute, now: 1),
    IntentEvent(kind: ieContribute, now: 1), IntentEvent(kind: ieContribute, now: 1),
    IntentEvent(kind: ieSubmit, now: 2),
  ]
  let reduced = reduce(drv, effect, ctx, events)
  var incremental = newIntent(drv, effect, ctx)
  for ev in events: incremental.apply(drv, ev)
  doAssert reduced.state == incremental.state
  doAssert reduced.state == lsSubmitted
  echo "state = reduce(log): OK"

echo "lifecycle: all transitions verified"
