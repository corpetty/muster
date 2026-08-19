## Anonymous coordination state (spec:
## contracts/specs/derived-exo-f60.spec.json, invariant 9, catastrophic).
##
## When a driver declares an anonymous membership model, the signer of a
## contribution is an INPUT to verification but is never retained. Anonymity is a
## property of the client's own state, not of its rendering: identity is absent
## from UI state, from every log path, from ordering, from logical-event timing,
## and from every retained artifact — not merely unshown.
##
## The design achieves this structurally: `ingest` takes the signer, uses it to
## verify (elsewhere), and stores nothing derived from it. UI state is n-of-m
## slot counts plus arrival-ordered opaque contributions; log/events/exports carry
## no signer field. The retention schema below is the declared, enumerable surface
## a probe walks to prove no field is identity-derived.

import ../drivers/driver

type
  Arrival* = object
    contribution*: Contribution   ## opaque bytes
    signer*: string               ## used only to verify; NEVER retained

  SlotState* = object             ## the UI-observable state
    filled*: int
    total*: int
    contributions*: seq[seq[byte]]  ## opaque, arrival order; no signer

  LogRecord* = object
    seqNo*: int
    kind*: string                 ## "accepted" | "round-advanced" | "error" | ...
    detail*: string               ## message; never a signer
    logPos*: int

  StateEvent* = object            ## a logical state-update event
    logicalClock*: int
    filled*: int
    total*: int

  AnonCoordination* = object
    total*: int
    state*: SlotState
    log*: seq[LogRecord]
    events*: seq[StateEvent]
    clock*: int

proc newAnonCoordination*(total: int): AnonCoordination =
  result.total = total
  result.state = SlotState(filled: 0, total: total, contributions: @[])
  result.clock = 0

proc ingest*(co: var AnonCoordination, a: Arrival) =
  ## The signer (`a.signer`) is used by the caller to verify; nothing here stores
  ## it or any value derived from it. State advances on arrival/log position only.
  inc co.state.filled
  co.state.contributions.add a.contribution.bytes
  inc co.clock
  co.log.add LogRecord(seqNo: co.log.len, kind: "accepted",
                       detail: "contribution accepted at slot " & $co.state.filled,
                       logPos: co.log.len)
  co.events.add StateEvent(logicalClock: co.clock, filled: co.state.filled,
                           total: co.total)

# ── The declared retention schema: every retained record type × field, with
# whether the field is derived from signer identity. A probe walks the whole
# schema to prove none is identity-derived (invariant 9, s5). Adding a
# signer-bearing field would have to appear here as identity-derived (caught) or
# be omitted (then the s1/s2 probes catch it in state/logs). ───────────────────
type RetentionField* = object
  recordType*: string
  field*: string
  identityDerived*: bool

proc retentionSchema*(): seq[RetentionField] =
  @[
    RetentionField(recordType: "log_record", field: "seqNo", identityDerived: false),
    RetentionField(recordType: "log_record", field: "kind", identityDerived: false),
    RetentionField(recordType: "log_record", field: "detail", identityDerived: false),
    RetentionField(recordType: "log_record", field: "logPos", identityDerived: false),
    RetentionField(recordType: "reduced_state", field: "filled", identityDerived: false),
    RetentionField(recordType: "reduced_state", field: "total", identityDerived: false),
    RetentionField(recordType: "reduced_state", field: "contributions", identityDerived: false),
    RetentionField(recordType: "state_event", field: "logicalClock", identityDerived: false),
    RetentionField(recordType: "state_event", field: "filled", identityDerived: false),
    RetentionField(recordType: "state_event", field: "total", identityDerived: false),
    RetentionField(recordType: "cache", field: "contributionByLogPos", identityDerived: false),
    RetentionField(recordType: "export", field: "filled", identityDerived: false),
    RetentionField(recordType: "export", field: "total", identityDerived: false),
    RetentionField(recordType: "export", field: "contributions", identityDerived: false),
    RetentionField(recordType: "crash_dump", field: "log", identityDerived: false),
    RetentionField(recordType: "crash_dump", field: "reduced_state", identityDerived: false),
  ]
