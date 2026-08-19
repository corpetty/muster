## Driver interface and the driver-generic core (spec:
## contracts/specs/derived-exo-2dc.spec.json, invariant 6).
##
## The core never interprets contribution bytes — drivers do. Rounds, the
## serialization domain, the membership model, and finality are all
## *driver-described* via describe(), never hardcoded in the core. The core
## treats a contribution as an opaque blob: it asks the driver to verify it and
## routes on the boolean result plus the descriptor, so a different driver
## (different round count / membership / finality) needs no core change.
##
## A stub driver lives here for the conformance probes; real drivers (Safe at
## P2, threshold at P6) implement the same interface.

type
  MembershipModel* = enum
    mmAnonymous = "anonymous"
    mmNamed = "named"

  FinalityType* = enum
    finImmediate = "immediate"
    finProbabilistic = "probabilistic"
    finExternal = "external"

  DriverDescriptor* = object
    rounds*: int                 ## e.g. Safe r=1, FROST r=2 — never assumed
    serializationDomain*: string ## domain tag for contribution bytes
    membership*: MembershipModel
    finality*: FinalityType
    threshold*: int              ## accepted contributions needed to close a round

  Contribution* = object
    bytes*: seq[byte]            ## OPAQUE to the core; only the driver reads it

  Driver* = ref object of RootObj

method describe*(d: Driver): DriverDescriptor {.base, gcsafe.} =
  raise newException(CatchableError, "Driver.describe is abstract")

method verifyContribution*(d: Driver, c: Contribution, round: int): bool {.base, gcsafe.} =
  raise newException(CatchableError, "Driver.verifyContribution is abstract")

# ── The driver-generic core: a round-based collection driven only by describe() ─
type Collection* = object
  descriptor*: DriverDescriptor
  round*: int             ## 1-based current round
  acceptedThisRound*: int
  complete*: bool

proc startCollection*(driver: Driver): Collection =
  ## The core snapshots the driver's declared policy once; everything downstream
  ## reads from this descriptor, never from a hardcoded constant.
  result.descriptor = driver.describe()
  result.round = 1
  result.acceptedThisRound = 0
  result.complete = false

proc submit*(col: var Collection, driver: Driver, c: Contribution) =
  ## Core routing. It does NOT read c.bytes. It asks the driver whether the
  ## contribution is valid this round, then advances round/finality purely from
  ## the descriptor. Round count and completion are describe()-derived.
  if col.complete: return
  let accepted = driver.verifyContribution(c, col.round)   # only the driver reads bytes
  if accepted:
    inc col.acceptedThisRound
    if col.acceptedThisRound >= col.descriptor.threshold:
      if col.round >= col.descriptor.rounds:
        col.complete = true
      else:
        inc col.round
        col.acceptedThisRound = 0

# Core-observable policy, always sourced from the descriptor (never hardcoded).
proc roundCount*(col: Collection): int = col.descriptor.rounds
proc membershipDispatch*(col: Collection): MembershipModel = col.descriptor.membership
proc finalityHandling*(col: Collection): FinalityType = col.descriptor.finality

# ── Stub driver: a configurable descriptor + a byte-independent verify result ──
# The verify result is fixed by construction (not derived from bytes) so a probe
# can prove the CORE's routing is byte-independent while holding the driver's
# answer constant. Real drivers interpret the bytes here.
type StubDriver* = ref object of Driver
  descriptor*: DriverDescriptor
  verifyResult*: bool

method describe*(d: StubDriver): DriverDescriptor = d.descriptor
method verifyContribution*(d: StubDriver, c: Contribution, round: int): bool =
  d.verifyResult

proc newStubDriver*(rounds = 1, threshold = 2, domain = "muster.stub.v1",
                    membership = mmAnonymous, finality = finImmediate,
                    verifyResult = true): StubDriver =
  StubDriver(
    descriptor: DriverDescriptor(
      rounds: rounds, serializationDomain: domain,
      membership: membership, finality: finality, threshold: threshold),
    verifyResult: verifyResult)
