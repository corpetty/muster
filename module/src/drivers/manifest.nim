## The action manifest — one per-action object answering the five card questions
## (design: docs/design/action-manifest.md, epic exo-002, slice exo-002.1):
##   what will it do       → the effect (already on the proposal)
##   what is needed        → requirements  (module / environment / authority / infra / capability)
##   what will it touch    → touches       (targets read or written)
##   what will happen      → disclosure    (which fields reach which observer class)
##   how do we agree       → agreement     (the driver's describe(): rounds, threshold, membership, finality)
##
## It is a function of driver + EFFECT, not driver alone: the generic invoke driver
## carries no module — the module/method live in the effect — so the manifest is
## computed per proposal. The default is UNDECLARED, which the card shows as such;
## a manifest is never guessed. consistencyFailures() is the conformance rule: a
## driver whose manifest contradicts its own describe() (settles externally but
## names no environment or public disclosure; requires named members but names no
## authority) fails the suite. Invariant 3: a manifest describes — it grants nothing.

import ../dcbor/dcbor
import ../intents/materialization
import ../intents/disclosure
import ./driver
export disclosure

type
  RequirementKind* = enum
    rqModule      = "module"       ## a Logos module must be loaded (name = module id)
    rqEnvironment = "environment"  ## a chain / network must be reachable (name = env id)
    rqAuthority   = "authority"    ## the contributor must hold a key the driver accepts
    rqInfra       = "infra"        ## user-configured infrastructure (an RPC, a store node)
    rqCapability  = "capability"   ## a host (Basecamp) capability grant

  RequirementScope* = enum
    rsInstance    = "instance"     ## this client must satisfy it
    rsContributor = "contributor"  ## each participant who contributes must satisfy it

  Requirement* = object
    kind*: RequirementKind
    name*: string
    scope*: RequirementScope

  TouchMode* = enum
    tmRead  = "read"
    tmWrite = "write"

  Touch* = object
    target*: string   ## "safe:0x…", "module:lez_core.transfer_private", "chain:31337"
    mode*: TouchMode

  ActionManifest* = object
    declared*: bool               ## false = the driver has not declared (shown, never guessed)
    agreement*: DriverDescriptor  ## how agreement is made — always describe()
    requirements*: seq[Requirement]
    discloses*: seq[DisclosureRow] ## BEYOND baselineDisclosure()
    touches*: seq[Touch]

proc req*(kind: RequirementKind, name: string, scope = rsInstance): Requirement =
  Requirement(kind: kind, name: name, scope: scope)

proc touch*(target: string, mode: TouchMode): Touch =
  Touch(target: target, mode: mode)

method manifest*(d: Driver, effect: Effect): ActionManifest {.base, gcsafe.} =
  ## Default: undeclared. The agreement half is derivable from describe(); nothing
  ## else is, so nothing else is filled in.
  ActionManifest(declared: false, agreement: d.describe())

proc fullDisclosure*(m: ActionManifest): seq[DisclosureRow] =
  ## Baseline (core-added) + the driver's declared rows. This is what the card shows.
  baselineDisclosure() & m.discloses

proc fieldText*(e: Effect, name: string): string =
  ## Read a text field off the effect (the invoke driver's module/method live here).
  for (k, v) in e.fields:
    if k == name and v.kind == ckText: return v.t
  ""

proc consistencyFailures*(m: ActionManifest): seq[string] =
  ## The rules a manifest must satisfy to be believed. Empty = consistent.
  if not m.declared:
    result.add "manifest is undeclared"
    return
  for r in m.requirements:
    if r.name.len == 0: result.add "requirement with empty name (" & $r.kind & ")"
  for t in m.touches:
    if t.target.len == 0: result.add "touch with empty target"
  if m.agreement.finality == finExternal:
    var hasEnv, hasChainRow, hasWrite = false
    for r in m.requirements:
      if r.kind == rqEnvironment: hasEnv = true
    for d in m.discloses:
      if d.to == obChainObserver: hasChainRow = true
    for t in m.touches:
      if t.mode == tmWrite: hasWrite = true
    if not hasEnv: result.add "external finality but no environment requirement"
    if not hasChainRow: result.add "external finality but nothing disclosed to the chain observer"
    if not hasWrite: result.add "external finality but no write touch"
  if m.agreement.membership == mmNamed:
    var hasAuth = false
    for r in m.requirements:
      if r.kind == rqAuthority and r.scope == rsContributor: hasAuth = true
    if not hasAuth: result.add "named membership but no contributor-scoped authority requirement"

proc consistent*(m: ActionManifest): bool = consistencyFailures(m).len == 0

# ── The stub declares too, so the conformance probes grade it like a real driver ──
method manifest*(d: StubDriver, effect: Effect): ActionManifest =
  ## A stub is configurable (probes randomize finality/membership), so its manifest
  ## follows its own descriptor: whatever describe() claims, the manifest is
  ## consistent with it. It touches and needs nothing real.
  result = ActionManifest(declared: true, agreement: d.descriptor)
  if d.descriptor.finality == finExternal:
    result.requirements.add req(rqEnvironment, "stub-env")
    result.discloses.add row("effect", obChainObserver)
    result.touches.add touch("stub:state", tmWrite)
  if d.descriptor.membership == mmNamed:
    result.requirements.add req(rqAuthority, "stub-member", rsContributor)
