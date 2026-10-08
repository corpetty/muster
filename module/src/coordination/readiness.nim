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
##
## A module requirement is graded in three states (exo-dcc.10): running, installed but
## not running, not installed — read from the host's module registry first
## (module_registry.nim); muster calls into a module only once the registry reports it
## ready, since a call to one installed but not loaded waits out its whole deadline. The
## registry's `ready` is met (exo-dcc.11): Basecamp's lp_get_methods is always [], so the
## module's own answer cannot confirm it there; a call that then fails is reported at the
## call. The item says which (`moduleState`) and, where installing would help, the catalogue package
## to install (`install`, which the driver may name apart from the module), so the card
## can raise Basecamp's `packages.install` for it.

import std/[json, strutils, sequtils]
import ../drivers/driver
import ../drivers/manifest
import ../intents/materialization   # Eligibility — the driver's own "would your contribution count"
import ../crypto/secp256k1     # Address
import ../crypto/curve25519    # Ed25519Pub
import ../drivers/safe_rpc     # probeRpc
import ./invoker               # Invoker.methodsOf (is the module loaded?)
import ./module_registry       # modules_state's answer: installed? running? (exo-dcc.10)
import ../wallet/btc_adapter   # probeBitcoind (exo-a50.2.6)
import ../wallet/redact        # an endpoint as it may be shown (exo-14f.2)
export manifest, driver, module_registry

type
  ReadyStatus* = enum
    rdMet     = "met"
    rdMissing = "missing"
    rdUnknown = "unknown"

  Grade* = tuple[status: ReadyStatus, detail: string]

  ModuleState* = enum
    ## Where a required module stands on THIS instance (exo-dcc.10).
    msNone         = ""               ## not a module requirement
    msReady        = "ready"          ## running: the host's registry reports it ready, or (no registry) it listed its methods to muster
    msStarting     = "starting"       ## the host is bringing it up (loading / loaded)
    msInstalled    = "installed"      ## installed, not running (unloaded, stopping, or a state this client does not know)
    msNotInstalled = "not-installed"  ## the host does not know it: install it
    msError        = "error"          ## its load failed, or it exited without being asked to
    msUnknown      = "unknown"        ## this host cannot say whether it is installed

  ModuleGrade* = tuple[status: ReadyStatus, detail: string, state: ModuleState]

  ## One closure per requirement kind. A nil closure = the host cannot probe it → unknown.
  ReadinessProbe* = object
    moduleLoaded*:        proc(name: string): ModuleGrade {.gcsafe.}
    moduleDeclared*:      proc(name: string): bool {.gcsafe.}
                          ## whether muster declares the module: reopening Muster starts
                          ## it, and it answers Muster. nil = cannot tell.
    environmentReachable*: proc(name: string): Grade {.gcsafe.}
    authorityHeld*:       proc(name: string): Grade {.gcsafe.}
    infraConfigured*:     proc(name: string): Grade {.gcsafe.}
    capabilityGranted*:   proc(name: string): Grade {.gcsafe.}
    pays*: Eligibility    ## whether this instance settles a part itself (a `payer` slot is
                          ## its own); elNo drops those slots, elUnknown keeps them, unknown

  ReadinessItem* = object
    requirement*: Requirement
    status*: ReadyStatus
    detail*: string
    remedy*: string
    moduleState*: ModuleState  ## a module requirement's state; msNone for any other kind
    install*: string           ## the package to install when installing would help (not
                               ## met, and not installed or cannot say); "" otherwise
    request*: string           ## an app-to-app intent the card can raise for it ("" = none):
                               ## monero.wallet.unlock when a Monero wallet must be opened —
                               ## the wallet app asks for the password, never muster (exo-dcc.5)

  Readiness* = object
    declared*: bool
    ready*: bool               ## every requirement met (false when undeclared)
    unknown*: int              ## how many could not be graded
    items*: seq[ReadinessItem]

proc remedyFor*(r: Requirement): string =
  ## The action the card offers next to a non-met requirement. The module only names
  ## it; the host performs it. A module's depends on its state (moduleRemedy); this is
  ## its remedy when the state is not known.
  case r.kind
  of rqModule:      "install " & r.installPackage() & " from Basecamp's Package Manager"
  of rqEnvironment:
    if r.name.startsWith("bip122:"): "point Settings → Bitcoin node at a node on " & r.name & " (set_setting btc-rpc)"
    elif r.name.startsWith("monero:"):
      "open your Monero wallet for " & r.name & " in Monero Wallet: it asks for the password (monero.wallet.unlock)"
    elif r.name.startsWith("lez:"): "point Settings → LEZ sequencer at a node serving " & r.name & " (set_setting lez-rpc, lez-chain)"
    else: "point the RPC setting at a node on " & r.name & " (set_setting rpc)"
  of rqAuthority:
    if r.name == "split-party": "only the people a split names agree to it — if you owe a share, ask for the split to be proposed with you in it"
    else: "use a key that is a recognized " & r.name & " — or take part without signing"
  of rqInfra:
    if r.name == "lez-account": "set up a funded LEZ account in the LEZ Wallet App"
    elif r.name == "lez-rpc": "point Settings → LEZ sequencer at your own (set_setting lez-rpc)"
    elif r.name == "lez-member-funded": "send native LEZ to your member account: on LEZ v0.3 every vote pays its own fee"
    elif r.name == "bitcoind-rpc": "point Settings → Bitcoin node at your own node (set_setting btc-rpc)"
    else: "configure " & r.name & " (set_setting " & r.name & ")"
  of rqCapability:  "grant the " & r.name & " capability in the host"
  of rqAddress:     "share a receiving address when the proposal asks (compose / share)"
  of rqAsset:       "choose an asset and amount from your holdings (compose)"

proc moduleRemedy*(r: Requirement, state: ModuleState,
                   declared: proc(name: string): bool {.gcsafe.} = nil): string =
  ## The next step for a module requirement that is not met, by where the module stands.
  ## Installing goes through Basecamp's Package Manager, on the person's confirmation.
  ## `declared` says whether muster declares the module (nil = cannot tell).
  let known = declared != nil
  let mine = known and declared(r.name)
  case state
  # Basecamp loads a core module only when an app that depends on it opens (its required
  # and installed optional dependencies); a restart does not, and nothing else does.
  # Reopening Muster starts the modules Muster declares, and no others (Basecamp 0.3.2).
  of msInstalled:
    if not known: "start " & r.name & ": close and reopen Muster, or open the app that uses it"
    elif mine: "start " & r.name & ": close and reopen Muster"
    else: "start " & r.name & ": open the app that uses it, or load it in Basecamp's Modules tab"
  of msStarting: "wait for " & r.name & " to finish starting"
  of msError: r.name & " failed to load: see Basecamp's logs; reinstalling " & r.installPackage() & " may help"
  # running by the host's word is met (exo-dcc.11): nothing to do
  of msReady: ""
  of msNotInstalled, msUnknown, msNone: remedyFor(r)

proc gradeModuleRecord*(name: string, a: ModuleRecordAnswer): ModuleGrade =
  ## A module graded from what the host's registry says of it (exo-dcc.10). `ready` is
  ## met (exo-dcc.11): it is the host's word, and in Basecamp muster has no other —
  ## lp_get_methods always returns [] there (logos-protocol's remote transport does not
  ## implement introspection), so an empty list from the module says nothing. The
  ## registry's ready goes true a few hundred ms before a caller's token handshake
  ## completes; a call made in that moment fails and is reported at the call, since
  ## readiness is a guide. Unanswered (no registry) and no methods from the module: it is
  ## not loaded, and whether it is installed is not known.
  if not a.answered:
    return (rdMissing, name & " is not loaded (this host cannot say whether it is installed)", msUnknown)
  if not a.known: return (rdMissing, name & " is not installed", msNotInstalled)
  case a.state
  of "loading", "loaded": (rdUnknown, name & " is starting", msStarting)
  of "ready": (rdMet, name & " is running", msReady)
  of "stopping": (rdMissing, name & " is stopping", msInstalled)
  of "error": (rdMissing, name & " failed to load" & (if a.reason.len > 0: ": " & a.reason else: ""), msError)
  else:
    # "unloaded" — and any state this client does not know, which the registry's
    # forward-compatibility rule reads as "not loaded", never an error
    (rdMissing, name & " is installed but not running", msInstalled)

proc gradeModule(p: ReadinessProbe, r: Requirement): ModuleGrade =
  if p.moduleLoaded == nil: return (rdUnknown, "this host cannot check a module requirement", msUnknown)
  try: p.moduleLoaded(r.name)
  except CatchableError as e: (rdUnknown, "probe failed: " & e.msg, msUnknown)

proc grade(p: ReadinessProbe, r: Requirement): Grade =
  # address/asset are party-supplied material (proposer/counterparty), not an instance
  # prerequisite: readiness reports them unknown and the offers surface (exo-45e K4)
  # grades which of a participant's own holdings fill them. unknown, never a silent met.
  if r.kind in {rqAddress, rqAsset}:
    return (rdUnknown, $r.party & " supplies this " & $r.needs.class &
      " material at compose/contribute — graded by offers, not instance readiness")
  let f = case r.kind
    of rqEnvironment: p.environmentReachable
    of rqAuthority:   p.authorityHeld
    of rqInfra:       p.infraConfigured
    of rqCapability:  p.capabilityGranted
    of rqModule, rqAddress, rqAsset: nil   # a module is gradeModule's; address/asset above
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
    if r.party notin {rpInstance, rpContributor, rpPayer}: continue
    # a payer's slot (their own share) is only a payer's: the creditor who agrees pays
    # nothing (exo-272). Unknown keeps it — shown and graded, never silently dropped.
    if r.party == rpPayer and p.pays == elNo: continue
    var it = ReadinessItem(requirement: r)
    if r.kind == rqModule:
      let g = gradeModule(p, r)
      (it.status, it.detail, it.moduleState) = (g.status, g.detail, g.state)
      if g.status != rdMet:
        it.remedy = moduleRemedy(r, g.state, p.moduleDeclared)
        if g.state in {msNotInstalled, msUnknown}: it.install = r.installPackage()
    else:
      (it.status, it.detail) = grade(p, r)
      if it.status != rdMet: it.remedy = remedyFor(r)
      if it.status != rdMet and r.kind == rqEnvironment and r.name.startsWith("monero:"):
        it.request = "monero.wallet.unlock"
    result.items.add it
    if it.status != rdMet: result.ready = false
    if it.status == rdUnknown: inc result.unknown

# ── The host's facts → a probe. Plain data + two optional seams, so a test can build
# the SAME probe the module builds (without a host) and grade a real driver's manifest.
type
  HostFacts* = object
    rpcUrl*: string                ## "" = no RPC configured
    expectedChainId*: int          ## what an EVM environment requirement "eip155:<id>" must match
    myAddress*: Address            ## this instance's secp authorization identity
    myEd*: Ed25519Pub              ## this instance's Ed25519 encryption identity
    signers*: seq[Address]         ## the eip191 signer set ("signer")
    roster*: seq[Ed25519Pub]       ## the room roster ("roster-member")
    invoker*: Invoker              ## nil = cannot ask the host which modules are loaded
    moduleRecord*: ModuleRecordProbe
                                   ## modules_state.module_record — installed? starting?
                                   ## ready? failed? — asked before muster calls into a
                                   ## module; bounded and cached by the host (exo-dcc.10).
                                   ## nil = no registry: the module itself is asked, and
                                   ## whether it is installed is unknown
    callableWithoutRegistry*: proc(name: string): bool {.gcsafe.}
                                   ## when the registry cannot be asked, which modules
                                   ## muster may still call to see if they run: the ones it
                                   ## REQUIRES, which the host loads before muster. A call
                                   ## to a module that is not running blocks for lp's whole
                                   ## deadline (20 s, measured in the runner), so any other
                                   ## grades unknown, uncalled — an optional dependency
                                   ## too, which is loaded only when installed. nil = ask
                                   ## any module.
    declared*: proc(name: string): bool {.gcsafe.}
                                   ## the modules muster declares, required or optional:
                                   ## reopening Muster starts an installed one (Basecamp
                                   ## 0.3.2), so that is its remedy (exo-dcc.1). nil = the
                                   ## callableWithoutRegistry set.
    safe*: Address                ## the Safe whose owner set "safe-owner" is graded against
    rpcProbe*: proc(url: string): tuple[ok: bool, chainId: int, detail: string] {.gcsafe.}
                                   ## nil = use the real probeRpc
    lezReady*: proc(): Grade {.gcsafe.}
                                   ## grade a "lez-account" infra requirement — does this
                                   ## instance have a set-up, funded LEZ account? The host
                                   ## bakes wallet/lez_readiness.lezAccountStatus (+ the
                                   ## required amount) into this closure; nil = unknown.
                                   ## Muster only DETECTS; setup is the LEZ Wallet App's
                                   ## job (exo-44b), which the remedy names.
    lezRpcUrl*: string             ## the user's LEZ sequencer JSON-RPC ("" = none configured)
    btcRpcUrl*: string             ## the user's Bitcoin node ("" = none configured)
    moneroWallet*: proc(chain: string): Grade {.gcsafe.}
                                   ## grade a "monero:<ref>" environment: whether THIS member's
                                   ## open Monero wallet can vouch for and confirm a request on
                                   ## that chain (open, on its network, not view-only) — or,
                                   ## for a debtor, that none is needed (they pay from any
                                   ## wallet). The host reads wallet_status, cached; nil =
                                   ## cannot read a Monero wallet → unknown (exo-dcc.5).
    btcProbe*: proc(url: string): tuple[ok: bool, chain: string, detail: string] {.gcsafe.}
                                   ## which chain (CAIP-2) the node serves; nil = the real
                                   ## probeBitcoind (getblockhash 0)
    myBtcKey*: string              ## this instance's compressed secp key, hex (exo-a50.2.6)
    btcSigners*: seq[string]       ## the intent's Bitcoin account keys, hex ("" = none)
    pays*: Eligibility             ## whether this instance settles a part of the intent itself
                                   ## (Driver settlesAPart, exo-272); elUnknown = not asked
    contributes*: Eligibility      ## the intent's driver's own answer for this instance —
                                   ## Driver.mayContribute(effect, my names) (exo-ed5) — for an
                                   ## authority whose parties the effect names ("split-party",
                                   ## exo-272). elUnknown (the default) = not asked → unknown.
    ownersProbe*: proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] {.gcsafe.}
                                   ## nil = use the real getOwners. The Safe owner set is
                                   ## read FROM THE CHAIN (F-10), never the configured set:
                                   ## without a chain read we do not KNOW the real owners, so
                                   ## the grade is unknown, never a fabricated met (rule s4/s5).

proc probeFromFacts*(f: HostFacts): ReadinessProbe =
  let facts = f
  result.pays = facts.pays
  result.infraConfigured = proc(name: string): Grade =
    if name == "rpc":
      if facts.rpcUrl.len > 0: (rdMet, "rpc = " & redactUrl(facts.rpcUrl))
      else: (rdMissing, "no RPC endpoint configured")
    elif name == "bitcoind-rpc":
      # a Bitcoin proposal INTRODUCES its node (exo-a50.2.6): read UTXOs, broadcast
      if facts.btcRpcUrl.len > 0: (rdMet, "bitcoind = " & redactUrl(facts.btcRpcUrl))
      else: (rdMissing, "no Bitcoin node configured")
    elif name == "lez-rpc":
      # the user's LEZ sequencer, which the live LEZ multisig and LEZ-FROST paths submit
      # through (JSON-RPC). Configured is what this grades; reachability is the zone's.
      if facts.lezRpcUrl.len > 0: (rdMet, "lez-rpc = " & redactUrl(facts.lezRpcUrl))
      else: (rdMissing, "no LEZ sequencer configured")
    elif name == "lez-account":
      # A set-up, funded LEZ account. DETECTED here (via the host's lezReady closure over
      # lez_core); PROVISIONED in the LEZ Wallet App (exo-44b) — the remedy names it.
      if facts.lezReady != nil: facts.lezReady()
      else: (rdUnknown, "cannot check the LEZ account — no zone probe")
    elif name == "lez-member-funded":
      # the v0.3 port: every vote pays its own fee (exo-eb6.4.4). Which member account
      # votes is chosen at the vote, so this host does not read its balance here.
      (rdUnknown, "your member account must hold native LEZ for its fee; it is read when you vote")
    else: (rdUnknown, "unrecognized infra requirement: " & name)
  result.environmentReachable = proc(name: string): Grade =
    if name.startsWith("bip122:"):
      # Bitcoin: ask the configured node which chain it serves (its genesis hash) —
      # never assumed from the setting (exo-a50.2.6)
      if facts.btcRpcUrl.len == 0:
        return (rdUnknown, "no Bitcoin node configured to ask which chain it serves")
      let probe = if facts.btcProbe != nil: facts.btcProbe else: probeBitcoind
      let (ok, chain, detail) = probe(facts.btcRpcUrl)
      if not ok: return (rdMissing, "Bitcoin node unreachable: " & detail)
      if chain == name: return (rdMet, detail)
      return (rdMissing, "the Bitcoin node serves " & chain & ", the action needs " & name)
    if name.startsWith("monero:"):
      if facts.moneroWallet == nil: return (rdUnknown, "this host cannot read a Monero wallet")
      return facts.moneroWallet(name)
    if not name.startsWith("eip155:"):
      # a chain (CAIP-2) this host has no probe for
      return (rdUnknown, "this host has no probe for " & name & " yet")
    if facts.rpcUrl.len == 0:
      return (rdUnknown, "no RPC configured to probe " & name & " through")
    let probe = if facts.rpcProbe != nil: facts.rpcProbe else: probeRpc
    let (ok, chain, detail) = probe(facts.rpcUrl)
    if not ok: (rdMissing, detail)       # the probe says why: unreachable, or cooling down
    elif name == "eip155:" & $chain: (rdMet, detail)
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
    of "btc-multisig-key":
      # whether MY key is one of the account's — never who else holds one (exo-a50.2.6)
      if facts.btcSigners.len == 0: (rdUnknown, "no Bitcoin account keys to grade against")
      elif facts.myBtcKey.toLowerAscii() in facts.btcSigners.mapIt(it.toLowerAscii()):
        (rdMet, "your key is one of the account's")
      else: (rdMissing, "your key is not one of the account's — your signature would not count")
    of "signer":
      if facts.myAddress in facts.signers: (rdMet, "your key is a configured signer")
      else: (rdMissing, "your key is not a configured signer")
    of "roster-member":
      if facts.myEd in facts.roster: (rdMet, "your encryption identity is on the room roster")
      else: (rdMissing, "your encryption identity is not on the room roster")
    of "split-party":
      # a split names its parties in the effect — each debtor and the creditor (exo-770) —
      # so the driver's own answer grades it; whether anyone ELSE is named, it never says
      case facts.contributes
      of elYes: (rdMet, "the split names you: your agreement counts")
      of elNo: (rdMissing, "the split does not name you: your agreement would not count")
      of elUnknown: (rdUnknown, "cannot tell whether the split names you")
    else: (rdUnknown, "unrecognized authority requirement: " & name)
  let declaredBy = (if facts.declared != nil: facts.declared else: facts.callableWithoutRegistry)
  result.moduleDeclared = declaredBy
  result.moduleLoaded = proc(name: string): ModuleGrade =
    # The host's registry first: muster calls into a module only once the host reports
    # it ready — a call to one installed but not loaded blocks for the caller's whole
    # deadline (20 s), and lp_get_methods takes none.
    var a = unanswered("no module registry")
    if facts.moduleRecord != nil:
      try: a = facts.moduleRecord(name)
      except CatchableError as e: a = unanswered("modules_state call failed: " & e.msg)
    if a.answered:
      # the registry's word stands; ready is met (exo-dcc.11). Muster's own call adds a
      # method count where the host lists them (in process); Basecamp lists none.
      var g = gradeModuleRecord(name, a)
      if g.state == msReady:
        if facts.invoker != nil:
          let methods = facts.invoker.methodsOf(name)
          if methods != nil and methods.kind == JArray and methods.len > 0:
            g.detail &= " (" & $methods.len & " methods)"
        if declaredBy != nil and not declaredBy(name):
          # with the access policy off it answers Muster; enforced, it is refused. Muster
          # cannot tell which while it can still ask the registry, so it says both.
          g.detail &= "; Muster does not declare it, so a host that enforces its access " &
                      "policy refuses Muster's calls to it"
      return g
    # the registry cannot say (the standalone runner has none; an access policy that
    # refuses it): does the module answer muster?
    let refused = policyRefused(a)
    let why = (if refused: "its access policy denies Muster the module registry, modules_state"
               else: "no module registry to ask")
    if facts.invoker == nil:
      return (rdUnknown, "no host invoker — cannot ask whether " & name & " is loaded", msUnknown)
    if facts.callableWithoutRegistry != nil and not facts.callableWithoutRegistry(name):
      # no registry, and not a module muster requires: a call could block for lp's whole
      # deadline, so it is not made
      return (rdUnknown, "this host cannot say whether " & name &
              " is installed or running (" & why & ")", msUnknown)
    let methods = facts.invoker.methodsOf(name)
    if methods != nil and methods.kind == JArray and methods.len > 0:
      return (rdMet, name & " is running (" & $methods.len & " methods)", msReady)
    if refused:
      # a host with an access policy is Basecamp, whose lp_get_methods is always []:
      # an empty list there says nothing, and a required module loaded before Muster
      return (rdUnknown, name & " lists no methods, and the host's access policy denies Muster " &
              "the module registry (modules_state): cannot say whether it is running", msUnknown)
    gradeModuleRecord(name, a)   # not loaded, with no registry to say why
  result.capabilityGranted = nil   # the host broker does not exist yet (exo-002.7) → unknown

proc rpcConnectivityRow*(url: string, chains: seq[int],
                         probe: proc(url: string): tuple[ok: bool, chainId: int, detail: string] {.gcsafe.} = nil): JsonNode =
  ## The room's RPC row (musterConnectivity, exo-428): the ONE endpoint that serves every
  ## `infra:rpc` and `environment: eip155:<id>` need, probed once (eth_chainId, `probe` or
  ## probeRpc) against `chains`, the chains the introducing proposals need (none = any).
  ## "down", "ok", or "warn" (it answers, for another chain). The endpoint is shown as
  ## redactUrl shows it: the row reaches the UI and the MUSTER-LP debug log, and a hosted
  ## RPC's URL may carry its key (exo-14f.2). The caller adds `introducedBy`.
  var level, detail: string
  if url.len == 0:
    level = "down"; detail = "no RPC endpoint configured"
  else:
    let p = if probe != nil: probe else: probeRpc
    let (ok, chain, d) = p(url)
    if not ok: (level = "down"; detail = d)
    elif chains.len == 0 or chain in chains: (level = "ok"; detail = d)
    else:
      level = "warn"
      detail = d & " (the proposal needs chain " & chains.mapIt($it).join(" / ") & ")"
  %*{"key": "rpc", "name": "RPC", "level": level, "detail": detail,
     "endpoint": redactUrl(url), "source": "proposal",
     "remedy": (if level == "ok": "" else: "point the RPC setting at a node for chain " &
                 chains.mapIt($it).join(" / ") & " (Settings)")}

# ── JSON, for the hosted surface and the card ─────────────────────────────────
proc toJson*(r: Requirement): JsonNode =
  result = %*{"kind": $r.kind, "name": r.name, "party": $r.party,
              "needs": {"class": $r.needs.class, "target": r.needs.target, "field": r.needs.field}}
  if r.kind == rqModule: result["install"] = %r.installPackage()
proc toJson*(d: DriverDescriptor): JsonNode =
  %*{"rounds": d.rounds, "threshold": d.threshold,
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
proc toJson*(it: ReadinessItem): JsonNode =
  ## One graded requirement: the requirement, its status, detail and remedy; a module's
  ## also its state and the package to install ("" when installing would not help).
  result = it.requirement.toJson()
  result["status"] = %($it.status); result["detail"] = %it.detail; result["remedy"] = %it.remedy
  if it.requirement.kind == rqModule:
    result["moduleState"] = %($it.moduleState); result["install"] = %it.install
  if it.request.len > 0: result["request"] = %it.request
proc toJson*(r: Readiness): JsonNode =
  var items = newJArray()
  for it in r.items: items.add it.toJson()
  %*{"declared": r.declared, "ready": r.ready, "unknown": r.unknown, "items": items}

proc kindNeeds*(m: ActionManifest, p: ReadinessProbe): JsonNode =
  ## What a kind asks of THIS instance before anything is proposed under it — its module
  ## requirements, graded exactly as the card grades them (the same items) — for the
  ## composer's kind list (coordinate_drivers, exo-dcc.10): a kind whose module is missing
  ## shows "Install …" rather than disappearing. Modules only: the rest of a manifest
  ## (an environment, an account, a share) depends on the proposal and is the card's.
  ## [] when undeclared or when it names no module this instance must hold.
  result = newJArray()
  if not m.declared: return
  var mods = m
  mods.requirements = @[]
  for r in m.requirements:
    if r.kind == rqModule: mods.requirements.add r
  for it in assessReadiness(mods, p).items: result.add it.toJson()
