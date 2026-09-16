## Readiness — one instance's answer to "what is needed, and do I have it?" for a
## proposed action (docs/design/action-manifest.md, exo-002.2).
##
## The manifest (drivers/manifest.nim) says what an action REQUIRES; readiness grades
## each requirement for THIS instance: met / missing / unknown, with the remedy the
## card offers (install / configure / authorize). Two rules keep it honest:
##   * unknown is a first-class answer — a probe the host cannot run (no invoker, no
##     RPC configured, no broker yet) reports unknown, never a silent met (the
##     null-ladder rule, exo-1ec.5);
##   * authority is graded about YOU only — whether your own key is a recognized
##     signer — never about which other member holds it (invariant 9).
## The probes are closures the host supplies (`HostFacts` + `probeFromFacts`), so the
## grading logic is a pure function testable without a host; the module itself never
## installs, fetches, or executes anything here (invariant 3).

import std/json
import ../drivers/driver
import ../drivers/manifest
import ../crypto/secp256k1     # Address
import ../crypto/curve25519    # Ed25519Pub
import ../drivers/safe_rpc     # probeRpc
import ./invoker               # Invoker.methodsOf (is the module loaded?)
export manifest, driver

type
  ReadyStatus* = enum
    rdMet     = "met"
    rdMissing = "missing"
    rdUnknown = "unknown"

  Grade* = tuple[status: ReadyStatus, detail: string]

  ## One closure per requirement kind. A nil closure = the host cannot probe it → unknown.
  ReadinessProbe* = object
    moduleLoaded*:        proc(name: string): Grade {.gcsafe.}
    environmentReachable*: proc(name: string): Grade {.gcsafe.}
    authorityHeld*:       proc(name: string): Grade {.gcsafe.}
    infraConfigured*:     proc(name: string): Grade {.gcsafe.}
    capabilityGranted*:   proc(name: string): Grade {.gcsafe.}

  ReadinessItem* = object
    requirement*: Requirement
    status*: ReadyStatus
    detail*: string
    remedy*: string

  Readiness* = object
    declared*: bool
    ready*: bool               ## every requirement met (false when undeclared)
    unknown*: int              ## how many could not be graded
    items*: seq[ReadinessItem]

proc remedyFor*(r: Requirement): string =
  ## The action the card offers next to a non-met requirement. The module only names
  ## it; the host performs it.
  case r.kind
  of rqModule:      "install the " & r.name & " module (host install path)"
  of rqEnvironment: "point the RPC setting at " & r.name & " (set_setting rpc)"
  of rqAuthority:   "use a key that is a recognized " & r.name & " — or take part without signing"
  of rqInfra:       "configure " & r.name & " (set_setting " & r.name & ")"
  of rqCapability:  "grant the " & r.name & " capability in the host"
  of rqAddress:     "share a receiving address when the proposal asks (compose / share)"
  of rqAsset:       "choose an asset and amount from your holdings (compose)"

proc grade(p: ReadinessProbe, r: Requirement): Grade =
  # address/asset are party-supplied material (proposer/counterparty), not an instance
  # prerequisite: readiness reports them unknown and the offers surface (exo-45e K4)
  # grades which of a participant's own holdings fill them. unknown, never a silent met.
  if r.kind in {rqAddress, rqAsset}:
    return (rdUnknown, $r.party & " supplies this " & $r.needs.class &
      " material at compose/contribute — graded by offers, not instance readiness")
  let f = case r.kind
    of rqModule:      p.moduleLoaded
    of rqEnvironment: p.environmentReachable
    of rqAuthority:   p.authorityHeld
    of rqInfra:       p.infraConfigured
    of rqCapability:  p.capabilityGranted
    of rqAddress, rqAsset: nil   # unreachable (handled above); keeps the case total
  if f == nil: return (rdUnknown, "this host cannot check a " & $r.kind & " requirement")
  try: f(r.name)
  except CatchableError as e: (rdUnknown, "probe failed: " & e.msg)

proc assessReadiness*(m: ActionManifest, p: ReadinessProbe): Readiness =
  ## Grade every requirement; ready iff all met. Undeclared → not ready, no items.
  result.declared = m.declared
  if not m.declared:
    result.ready = false
    return
  result.ready = true
  for r in m.requirements:
    # Readiness is about THIS instance's own slots: what the client must hold or reach
    # (instance) and whether YOUR key is a recognized signer (contributor). Proposer and
    # counterparty material is compose-time effect content / another party's holding —
    # surfaced by the offers surface (exo-45e K4), not gated here. The full manifest still
    # travels in the payload, so the card can show every requirement; only the graded
    # items and the ready verdict are the instance's own.
    if r.party notin {rpInstance, rpContributor}: continue
    let g = grade(p, r)
    result.items.add ReadinessItem(requirement: r, status: g.status, detail: g.detail,
                                   remedy: (if g.status == rdMet: "" else: remedyFor(r)))
    if g.status != rdMet: result.ready = false
    if g.status == rdUnknown: inc result.unknown

# ── The host's facts → a probe. Plain data + two optional seams, so a test can build
# the SAME probe the module builds (without a host) and grade a real driver's manifest.
type
  HostFacts* = object
    rpcUrl*: string                ## "" = no RPC configured
    expectedChainId*: int          ## what the environment requirement "chain:<id>" must match
    myAddress*: Address            ## this instance's secp authorization identity
    myEd*: Ed25519Pub              ## this instance's Ed25519 encryption identity
    signers*: seq[Address]         ## the eip191 signer set ("signer")
    roster*: seq[Ed25519Pub]       ## the room roster ("roster-member")
    invoker*: Invoker              ## nil = cannot ask the host which modules are loaded
    safe*: Address                 ## the Safe whose owner set "safe-owner" is graded against
    rpcProbe*: proc(url: string): tuple[ok: bool, chainId: int, detail: string] {.gcsafe.}
                                   ## nil = use the real probeRpc
    ownersProbe*: proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] {.gcsafe.}
                                   ## nil = use the real getOwners. The Safe owner set is
                                   ## read FROM THE CHAIN (F-10), never the configured set:
                                   ## without a chain read we do not KNOW the real owners, so
                                   ## the grade is unknown, never a fabricated met (rule s4/s5).

proc probeFromFacts*(f: HostFacts): ReadinessProbe =
  let facts = f
  result.infraConfigured = proc(name: string): Grade =
    if name == "rpc":
      if facts.rpcUrl.len > 0: (rdMet, "rpc = " & facts.rpcUrl)
      else: (rdMissing, "no RPC endpoint configured")
    else: (rdUnknown, "unrecognized infra requirement: " & name)
  result.environmentReachable = proc(name: string): Grade =
    if facts.rpcUrl.len == 0:
      return (rdUnknown, "no RPC configured to probe " & name & " through")
    let probe = if facts.rpcProbe != nil: facts.rpcProbe else: probeRpc
    let (ok, chain, detail) = probe(facts.rpcUrl)
    if not ok: (rdMissing, "RPC unreachable: " & detail)
    elif name == "chain:" & $chain: (rdMet, detail)
    else: (rdMissing, "RPC serves chain " & $chain & ", the action needs " & name)
  result.authorityHeld = proc(name: string): Grade =
    case name
    of "safe-owner":
      # Read the owner set FROM THE CHAIN (F-10), never a configured/self-injected set.
      # No RPC, or a read that fails, is unknown — never a fabricated met (rule s4/s5).
      if facts.rpcUrl.len == 0:
        (rdUnknown, "no RPC to read the Safe owner set — cannot confirm you are an owner")
      else:
        let probe = if facts.ownersProbe != nil: facts.ownersProbe else: getOwners
        let (known, owners, detail) = probe(facts.rpcUrl, facts.safe)
        if not known: (rdUnknown, "could not read the Safe owner set: " & detail)
        elif facts.myAddress in owners: (rdMet, "your key is a Safe owner (read from chain)")
        else: (rdMissing, "your key is not a Safe owner on-chain — your signature would not count")
    of "signer":
      if facts.myAddress in facts.signers: (rdMet, "your key is a configured signer")
      else: (rdMissing, "your key is not a configured signer")
    of "roster-member":
      if facts.myEd in facts.roster: (rdMet, "your encryption identity is on the room roster")
      else: (rdMissing, "your encryption identity is not on the room roster")
    else: (rdUnknown, "unrecognized authority requirement: " & name)
  result.moduleLoaded = proc(name: string): Grade =
    if facts.invoker == nil:
      return (rdUnknown, "no host invoker — cannot ask whether " & name & " is loaded")
    let methods = facts.invoker.methodsOf(name)
    if methods.kind == JArray and methods.len > 0: (rdMet, name & " is loaded (" & $methods.len & " methods)")
    else: (rdMissing, name & " is not loaded")
  result.capabilityGranted = nil   # the host broker does not exist yet (exo-002.7) → unknown

# ── JSON, for the hosted surface and the card ─────────────────────────────────
proc toJson*(r: Requirement): JsonNode =
  %*{"kind": $r.kind, "name": r.name, "party": $r.party,
     "needs": {"class": $r.needs.class, "target": r.needs.target, "field": r.needs.field}}
proc toJson*(d: DriverDescriptor): JsonNode =
  %*{"rounds": d.rounds, "threshold": d.threshold, "membership": $d.membership,
     "finality": $d.finality, "domain": d.serializationDomain}
proc toJson*(m: ActionManifest): JsonNode =
  var reqs = newJArray()
  for r in m.requirements: reqs.add r.toJson()
  var disc = newJArray()
  for d in m.fullDisclosure(): disc.add %*{"field": d.field, "to": $d.to}
  var touches = newJArray()
  for t in m.touches: touches.add %*{"target": t.target, "mode": $t.mode}
  %*{"declared": m.declared, "agreement": m.agreement.toJson(),
     "requirements": reqs, "discloses": disc, "touches": touches}
proc toJson*(r: Readiness): JsonNode =
  var items = newJArray()
  for it in r.items:
    var o = it.requirement.toJson()
    o["status"] = %($it.status); o["detail"] = %it.detail; o["remedy"] = %it.remedy
    items.add o
  %*{"declared": r.declared, "ready": r.ready, "unknown": r.unknown, "items": items}
