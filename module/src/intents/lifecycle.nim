## Intent lifecycle engine (FURPS F-3).
##
## The capstone that ties the invariant modules into a working coordination flow:
## an intent moves draft → proposed → collecting(round r) → executable → submitted
## → settling → final (plus dropped / expired), and the reducer that advances it is
## a pure fold over log events. It reuses the driver's round-based Collection
## (invariant 6 — rounds/threshold come from describe(), never hardcoded) for the
## collecting → executable transition, the effect's canonicalized materialization
## (invariant 1), and the signing context's expiry (invariant 2). State is
## reduce(log): nothing here is retained that the event stream can't rebuild.

import ../drivers/driver
import ./materialization
import ./signing_payload

type
  LifecycleState* = enum
    lsDraft = "draft"
    lsProposed = "proposed"
    lsCollecting = "collecting"
    lsExecutable = "executable"
    lsSubmitted = "submitted"
    lsSettling = "settling"
    lsFinal = "final"
    lsDropped = "dropped"
    lsExpired = "expired"

  Intent* = object
    effect*: Effect
    materialization*: Materialization
    context*: SigningContext           ## env / account / slot / expiry
    state*: LifecycleState
    collection*: Collection            ## driver round/threshold state

  IntentEventKind* = enum
    iePropose, ieContribute, ieSubmit, ieSettling, ieFinal, ieDrop, ieReorg

  IntentEvent* = object
    kind*: IntentEventKind
    contribution*: Contribution        ## for ieContribute (opaque to the core)
    now*: uint64                       ## logical time, for expiry

const terminal = {lsFinal, lsDropped, lsExpired}
const preSubmit = {lsDraft, lsProposed, lsCollecting, lsExecutable}

proc newIntent*(driver: Driver, effect: Effect, context: SigningContext): Intent =
  result.effect = effect
  result.context = context
  result.materialization = canonicalize(driver, effect)   # invariant 1: reviewed effect
  result.collection = startCollection(driver)             # invariant 6: rounds from describe()
  result.state = lsDraft

proc apply*(intent: var Intent, driver: Driver, ev: IntentEvent) =
  ## One reduction step. Idempotent-safe on terminal states; expiry pre-empts any
  ## pre-submit transition.
  # A reorg can un-finalize a final/settling intent (R-8), so it is handled ahead
  # of the terminal guard; every other event is inert once terminal.
  if ev.kind == ieReorg:
    if intent.state in {lsFinal, lsSettling}: intent.state = lsSettling
    return
  if intent.state in terminal: return
  if ev.now > intent.context.expiry and intent.state in preSubmit:
    intent.state = lsExpired
    return
  case ev.kind
  of iePropose:
    if intent.state == lsDraft: intent.state = lsProposed
  of ieContribute:
    if intent.state in {lsProposed, lsCollecting}:
      intent.state = lsCollecting
      intent.collection.submit(driver, ev.contribution)   # core never reads the bytes
      if intent.collection.complete:
        intent.state = lsExecutable
  of ieSubmit:
    if intent.state == lsExecutable: intent.state = lsSubmitted
  of ieSettling:
    if intent.state == lsSubmitted: intent.state = lsSettling
  of ieFinal:
    if intent.state in {lsSubmitted, lsSettling}: intent.state = lsFinal
  of ieReorg: discard   # handled above
  of ieDrop:
    intent.state = lsDropped

proc reduce*(driver: Driver, effect: Effect, context: SigningContext,
             events: seq[IntentEvent]): Intent =
  ## State = reduce(log): rebuild the intent from its event stream alone.
  result = newIntent(driver, effect, context)
  for ev in events:
    result.apply(driver, ev)
