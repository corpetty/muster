## The one list of driver kinds (exo-a50.1.2; seam S2 of docs/design/multisig-landscape.md).
##
## A KIND is the policy word recorded on each intent ("intent/<id>/policy"); it names
## the multisig family the intent is governed by. Before this list there were four —
## the registry's case arms, the module's resolver, roomDriverKinds' founding set, and
## the UI's proposal-kind mapping — and they disagreed, while the module resolved an
## UNKNOWN kind to the Safe. A proposal under a kind this client does not have then
## folded, verified and settled as a Safe transfer: a guess, where the design's rule is
## "shown, never guessed". Now:
##   * this list is the only place a kind is named; the registry, the founding set,
##     add-driver admission and the composer's offer (coordinate_drivers) read it;
##   * an unknown kind resolves to an UnsupportedDriver, which verifies nothing and
##     declares nothing, so its intents never count a contribution, and the live
##     propose / contribute paths refuse it outright.
## Each kind's family is held to contracts/families/registry.json by tests/kinds_test.nim.

import std/[json, sequtils]
import ./driver
import ./profile

type
  KindInfo* = object
    kind*: string             ## the policy word recorded on each intent
    family*: string           ## the registry family it instantiates
    label*: string            ## what a person calls it on the picker
    composes*: seq[string]    ## the proposals it serves: "payment" | "statement" | "action"
    founding*: bool           ## admitted in every room from the start; else only by an approved add-driver

const Kinds*: seq[KindInfo] = @[
  KindInfo(kind: "safe", family: "evm.safe", label: "Safe", composes: @["payment"], founding: true),
  KindInfo(kind: "threshold", family: "room.threshold", label: "Threshold", composes: @["statement"], founding: true),
  KindInfo(kind: "frost", family: "room.frost-scaffold", label: "FROST", composes: @["statement"], founding: true),
  KindInfo(kind: "invoke", family: "room.invoke", label: "Module action", composes: @["action"], founding: true),
  KindInfo(kind: "eip191", family: "room.eip191-attest", label: "Attest", composes: @["statement"], founding: true),
  KindInfo(kind: "unanimous", family: "room.threshold", label: "Unanimous", composes: @["statement"], founding: false)]

proc isKnownKind*(kind: string): bool = Kinds.anyIt(it.kind == kind)

proc foundingKinds*(): seq[string] =
  for k in Kinds:
    if k.founding: result.add k.kind

proc kindsFor*(proposal: string): seq[string] =
  ## The kinds the composer may offer for a proposal kind (payment / statement / action),
  ## in list order — "payment via FROST" is not a thing, so it is never offered.
  for k in Kinds:
    if proposal in k.composes: result.add k.kind

proc kindsJson*(admitted: seq[string]): JsonNode =
  ## Every kind this client has, and whether the joined room has admitted it — what the
  ## picker renders (an unadmitted, non-founding kind is offered as "propose adding it").
  result = newJArray()
  for k in Kinds:
    result.add %*{"kind": k.kind, "family": k.family, "label": k.label,
                  "composes": k.composes, "founding": k.founding,
                  "admitted": k.kind in admitted}

# ── an unknown kind: shown, never guessed ────────────────────────────────────
type UnsupportedDriver* = ref object of Driver
  kind*: string   ## the policy word this client has no driver for

method describe*(d: UnsupportedDriver): DriverDescriptor =
  ## One round, one approval — but no contribution ever verifies, so the intent can
  ## never collect. Nothing here is a claim about what the kind really needs.
  DriverDescriptor(rounds: 1, serializationDomain: "muster.unsupported." & d.kind,
                   finality: finImmediate, threshold: 1)

method verifyContribution*(d: UnsupportedDriver, c: Contribution, round: int): bool =
  ## This client cannot check a contribution under a kind it does not have, so none counts.
  false

proc newUnsupportedDriver*(kind: string): UnsupportedDriver = UnsupportedDriver(kind: kind)

proc resolveKind*(kind: string, build: proc(kind: string): Driver): Driver =
  ## The one resolution rule: a kind on the list is built by `build` (the host's own
  ## instance wiring); anything else is unsupported — never a fallback to another family.
  if isKnownKind(kind): build(kind) else: newUnsupportedDriver(kind)

proc supported*(d: Driver): bool =
  ## Whether this client can take part in an intent under `d`: its family is declared.
  d.profile().declared
