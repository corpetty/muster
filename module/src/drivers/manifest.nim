## The action manifest — one per-action object answering the five card questions
## (design: docs/design/action-manifest.md, epic exo-002, slice exo-002.1):
##   what will it do       → the effect (already on the proposal)
##   what is needed        → requirements  (module / environment / authority / infra / capability / address / asset)
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
##
## exo-45e (material + disclosure): every requirement carries a PARTY — who supplies
## it — and a NEEDS — the class of material that satisfies it and, for proposer /
## counterparty material, the effect field it lands in. This is what lets the compose
## menu, readiness, and the recipient's prompt each grade THEIR OWN slots (docs/design/
## material-and-disclosure.md §3.2). The party replaces the earlier instance/contributor
## scope; the material vocabulary (authority/address/asset/infra/capability) is closed.

import ../dcbor/dcbor
import ../intents/materialization
import ../intents/disclosure
import ./driver
export disclosure

type
  RequirementKind* = enum
    rqModule      = "module"       ## a Logos module must be loaded (name = module id)
    rqEnvironment = "environment"  ## a chain / network must be reachable (name = env id)
    rqAuthority   = "authority"    ## a party must hold a key the driver accepts
    rqInfra       = "infra"        ## user-configured infrastructure (an RPC, a store node)
    rqCapability  = "capability"   ## a host (Basecamp) capability grant
    rqAddress     = "address"      ## a party must supply a receiving address (exo-45e)
    rqAsset       = "asset"        ## a party must supply an asset + amount (exo-45e)

  RequirementParty* = enum
    ## WHO supplies the requirement (docs/design/material-and-disclosure.md §3.2).
    rpInstance     = "instance"      ## this client, whoever it is (an RPC, a loaded module)
    rpProposer     = "proposer"      ## bound at compose time and written INTO the effect
    rpContributor  = "contributor"   ## supplied by each contributor from their own holdings
    rpCounterparty = "counterparty"  ## held by a specific OTHER party, shared before the effect completes

  MaterialClass* = enum
    ## The closed vocabulary of material a party can hold (§3.1). Distinct from the
    ## requirement KIND: kind says what sort of prerequisite, class says what holding
    ## satisfies it. module/environment prerequisites map onto infra/capability material.
    mcAuthority  = "authority"   ## a key a driver accepts
    mcAddress    = "address"     ## a place to receive
    mcAsset      = "asset"       ## a balance at an account
    mcInfra      = "infra"       ## the ability to reach (an RPC, a module, a node)
    mcCapability = "capability"  ## a host grant

  MaterialNeed* = object
    ## The material that satisfies a requirement, and where a party-supplied one lands.
    class*: MaterialClass
    target*: string   ## the constraint: "safe:0x…", "chain:31337", "lez:*", "ETH", ""
    field*: string    ## the effect field this material binds to (proposer/counterparty); "" otherwise

  Requirement* = object
    kind*: RequirementKind
    name*: string
    party*: RequirementParty
    needs*: MaterialNeed

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

proc classForKind*(kind: RequirementKind): MaterialClass =
  ## The material class a requirement kind is satisfied by, by default. A driver can
  ## override via an explicit `needs`; the conformance check holds a participant
  ## requirement's class to this mapping so kind and class cannot drift apart.
  case kind
  of rqAuthority:   mcAuthority
  of rqAddress:     mcAddress
  of rqAsset:       mcAsset
  of rqInfra:       mcInfra
  of rqEnvironment: mcInfra      ## reaching a chain is infra you hold
  of rqModule:      mcCapability ## a loaded module is a capability the instance holds
  of rqCapability:  mcCapability

proc need*(class: MaterialClass, target = "", field = ""): MaterialNeed =
  MaterialNeed(class: class, target: target, field: field)

proc req*(kind: RequirementKind, name: string, party = rpInstance,
          needs = MaterialNeed(class: mcInfra, target: "", field: "")): Requirement =
  ## Build a requirement. When `needs` is left at the sentinel default, it is derived
  ## from the kind (class = classForKind(kind), target = name), so the common
  ## instance/contributor requirements stay a one-liner; a driver supplies an explicit
  ## `need(...)` only where the material carries an effect field (proposer/counterparty).
  var n = needs
  if n.target.len == 0 and n.field.len == 0:
    n = need(classForKind(kind), name)   # sentinel default → derive from the kind
  Requirement(kind: kind, name: name, party: party, needs: n)

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

proc hasField*(e: Effect, name: string): bool =
  for (k, _) in e.fields:
    if k == name: return true
  false

proc consistencyFailures*(m: ActionManifest, effect = Effect()): seq[string] =
  ## The rules a manifest must satisfy to be believed. Empty = consistent. When an
  ## `effect` is supplied, proposer/counterparty requirements are also held to name a
  ## field the effect actually carries — so a driver cannot require participant
  ## material that has nowhere to land (docs/design/material-and-disclosure.md §3.2).
  if not m.declared:
    result.add "manifest is undeclared"
    return
  for r in m.requirements:
    if r.name.len == 0: result.add "requirement with empty name (" & $r.kind & ")"
    # participant material: kind and declared class must agree (no drift).
    if r.party in {rpProposer, rpContributor, rpCounterparty}:
      if r.needs.class != classForKind(r.kind):
        result.add "requirement " & r.name & " (" & $r.kind & ") declares class " &
          $r.needs.class & ", expected " & $classForKind(r.kind)
    # proposer / counterparty material must land in an effect field.
    if r.party in {rpProposer, rpCounterparty}:
      if r.needs.field.len == 0:
        result.add "requirement " & r.name & " is " & $r.party & " but names no effect field"
      elif effect.fields.len > 0 and not effect.hasField(r.needs.field):
        result.add "requirement " & r.name & " binds effect field '" & r.needs.field &
          "' which the effect does not carry"
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
      if r.kind == rqAuthority and r.party == rpContributor: hasAuth = true
    if not hasAuth: result.add "named membership but no contributor authority requirement"

proc consistent*(m: ActionManifest, effect = Effect()): bool =
  consistencyFailures(m, effect).len == 0

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
    result.requirements.add req(rqAuthority, "stub-member", rpContributor)
