## Readiness (exo-002.2): one instance grading a real driver's manifest with the SAME
## probe the module builds from its facts. The done-when: a Safe intent on an instance
## without an RPC reports infra:missing with the remedy, and a non-owner reports
## authority:missing; unknown is first-class, never a silent met; undeclared is not
## ready. Needs the secp closure (SafeDriver) + libsodium (Ed25519) — see tests/README.md.

import std/[json, strutils, times, monotimes]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/threshold
import ../src/drivers/split
import ../src/coordination/intent_events   # effectFromJson
import ../src/drivers/manifest
import ../src/coordination/readiness
import ../src/coordination/invoker
import ../src/coordination/offers
import ../src/coordination/module_registry   # modules_state's answer, parsed + cached (exo-dcc.10)
import ../src/drivers/kinds
import ../src/crypto/secp256k1
import ../src/crypto/curve25519
import ../tools/action_corpus                # fixtureDriver: every kind, built as the corpus builds it

proc mkAddr(n: byte): Address = (for i in 0 ..< 20: result[i] = n)
proc ed(n: byte): Ed25519Pub = (for i in 0 ..< 32: result[i] = n)
proc item(r: Readiness, kind: RequirementKind): ReadinessItem =
  for it in r.items:
    if it.requirement.kind == kind: return it
  doAssert false, "no item of kind " & $kind

let effect = Effect(schemaId: "muster.effect.transfer.v1",
                    fields: @[("to", cbText("0xabc")), ("value", cbUint(5'u64))])
let owners = @[mkAddr(1), mkAddr(2), mkAddr(3)]
let safeDrv = newSafeDriver(chainId = 31337, safe = mkAddr(9), owners = owners, threshold = 2)
let m = safeDrv.manifest(effect)

proc chainProbe(id: int): proc(url: string): tuple[ok: bool, chainId: int, detail: string] {.gcsafe.} =
  (proc(url: string): tuple[ok: bool, chainId: int, detail: string] = (true, id, "chain " & $id))
proc ownersOnChain(os: seq[Address]): proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] {.gcsafe.} =
  (proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] = (true, os, "read from chain"))
let ownersUnreadable = proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] {.gcsafe.} =
  (false, @[], "eth_call reverted")

# ── 1. no RPC: infra missing (with remedy), AUTHORITY UNKNOWN (no chain read), env unknown ─
block:
  let f = HostFacts(rpcUrl: "", expectedChainId: 31337, myAddress: mkAddr(7), safe: mkAddr(9))
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert r.declared and not r.ready
  doAssert r.item(rqInfra).status == rdMissing and "set_setting rpc" in r.item(rqInfra).remedy
  doAssert r.item(rqAuthority).status == rdUnknown, "no chain read → cannot confirm you are an owner → unknown, never a fabricated met (s4/s5)"
  doAssert r.item(rqEnvironment).status == rdUnknown, "no RPC → the chain cannot be probed → unknown, not met"
  doAssert r.unknown == 2   # environment + authority
  echo "1. no RPC: infra missing, authority + env UNKNOWN (no fabricated access) OK"

# ── 2. an owner read FROM THE CHAIN, RPC on the right chain: ready ────────────────
block:
  var f = HostFacts(rpcUrl: "http://rpc", expectedChainId: 31337, myAddress: mkAddr(2), safe: mkAddr(9))
  f.rpcProbe = chainProbe(31337)
  f.ownersProbe = ownersOnChain(owners)   # the chain says mkAddr(2) is an owner
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert r.ready and r.unknown == 0, $r.toJson()
  doAssert "read from chain" in r.item(rqAuthority).detail
  for it in r.items: doAssert it.remedy.len == 0
  echo "2. owner read from chain + RPC on the expected chain: ready, no remedies OK"

# ── 2b. a NON-owner on-chain: authority MISSING (the false-green fix, s4) ──────────
block:
  var f = HostFacts(rpcUrl: "http://rpc", expectedChainId: 31337, myAddress: mkAddr(7), safe: mkAddr(9))
  f.rpcProbe = chainProbe(31337)
  f.ownersProbe = ownersOnChain(owners)   # mkAddr(7) is NOT in the chain owner set
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert not r.ready
  doAssert r.item(rqAuthority).status == rdMissing and "not a Safe owner on-chain" in r.item(rqAuthority).detail
  echo "2b. non-owner on-chain: authority MISSING — no key injected into the owner set OK"

# ── 2c. RPC up but getOwners fails: authority UNKNOWN (never a guess) ──────────────
block:
  var f = HostFacts(rpcUrl: "http://rpc", expectedChainId: 31337, myAddress: mkAddr(2), safe: mkAddr(9))
  f.rpcProbe = chainProbe(31337)
  f.ownersProbe = ownersUnreadable
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert r.item(rqAuthority).status == rdUnknown and "could not read" in r.item(rqAuthority).detail
  echo "2c. RPC up but owner read fails: authority UNKNOWN OK"

# ── 3. the RPC serves the WRONG chain: environment missing, named in the detail ─────
block:
  var f = HostFacts(rpcUrl: "http://rpc", expectedChainId: 31337, myAddress: mkAddr(2), safe: mkAddr(9))
  f.rpcProbe = chainProbe(1)
  f.ownersProbe = ownersOnChain(owners)
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert not r.ready
  doAssert r.item(rqEnvironment).status == rdMissing and "eip155:31337" in r.item(rqEnvironment).detail
  echo "3. wrong chain: environment missing, the expected chain named OK"

# ── 4. authority is about YOU only; a roster driver grades the Ed25519 identity ────
block:
  let roster = @[ed(1), ed(2)]
  let t = newThresholdDriver(roster, 2)
  let tm = t.manifest(effect)
  var f = HostFacts(myEd: ed(2), roster: roster)
  doAssert assessReadiness(tm, probeFromFacts(f)).ready
  f.myEd = ed(5)
  let r = assessReadiness(tm, probeFromFacts(f))
  doAssert r.item(rqAuthority).status == rdMissing
  # the detail says nothing about who IS on the roster — only that you are not
  doAssert "roster" in r.item(rqAuthority).detail and not ($r.toJson()).contains("0101")
  echo "4. roster authority graded against your own identity, naming no one else (inv 9) OK"

# ── 5. a module requirement: unknown without an invoker; met/missing with one ──────
block:
  let mm = ActionManifest(declared: true,
    agreement: DriverDescriptor(rounds: 1, serializationDomain: "x",
                                finality: finImmediate, threshold: 1),
    requirements: @[req(rqModule, "lez_core"), req(rqCapability, "coordinate.request")])
  let none = assessReadiness(mm, probeFromFacts(HostFacts()))
  doAssert none.item(rqModule).status == rdUnknown and none.item(rqCapability).status == rdUnknown
  doAssert none.unknown == 2 and not none.ready
  let inv = newLocalInvoker()
  inv.registerMethods("lez_core", %*[{"name": "transfer_private", "isInvokable": true}])
  var f = HostFacts(invoker: inv)
  let some = assessReadiness(mm, probeFromFacts(f))
  doAssert some.item(rqModule).status == rdMet, some.item(rqModule).detail
  let missing = assessReadiness(ActionManifest(declared: true, agreement: mm.agreement,
                                               requirements: @[req(rqModule, "nope")]),
                                probeFromFacts(f))
  doAssert missing.item(rqModule).status == rdMissing and
           "install nope from Basecamp's Package Manager" in missing.item(rqModule).remedy
  echo "5. module requirement: unknown with no invoker, met/missing with one; capability stays unknown OK"

# ── 6. undeclared is not ready, and the JSON says so ──────────────────────────────
block:
  let u = assessReadiness(ActionManifest(declared: false), probeFromFacts(HostFacts()))
  doAssert not u.ready and not u.declared and u.items.len == 0
  let j = u.toJson()
  doAssert j["declared"].getBool() == false and j["ready"].getBool() == false
  # the manifest JSON carries the full disclosure, baseline included
  let mj = m.toJson()
  var sawStore = false
  for d in mj["discloses"]: (if d["to"].getStr() == "store-node": sawStore = true)
  doAssert sawStore and mj["agreement"]["threshold"].getInt() == 2
  echo "6. undeclared → not ready; manifest JSON carries the baseline store-node rows OK"

# ── 7. a split's authority (split-party): graded from the split itself, about YOU (exo-272) ──
# The parties are named in the effect — each debtor and the creditor (exo-770) — so the
# driver's own answer (mayContribute) grades it; nothing names anyone else (invariant 9).
block:
  proc hexOf(b: openArray[byte]): string =
    const d = "0123456789abcdef"
    for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
  proc seed(n: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = n)
  let creditor = encFromSeed(seed(41))
  let debtor = encFromSeed(seed(42))
  let outsider = encFromSeed(seed(43))
  proc id(k: EncKeys): string = hexOf(k.identity().toBytes())
  proc names(k: EncKeys): seq[string] = @["ed:" & hexOf(k.identity().ed)]
  let sd = newSplitDriver(EvmSplitFamily, "eip155:31337", @[id(creditor), id(debtor), id(outsider)])
  let se = effectFromJson(splitEffectJson("eip155:31337", "ETH", "600", id(creditor),
    "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", evenShares("600", id(creditor), @[id(debtor)]), "lunch"))
  let sm = sd.manifest(se)
  proc authority(k: EncKeys): ReadinessItem =
    let r = assessReadiness(sm, probeFromFacts(HostFacts(contributes: sd.mayContribute(se, names(k)))))
    r.item(rqAuthority)
  doAssert authority(debtor).status == rdMet, authority(debtor).detail
  doAssert authority(creditor).status == rdMet, "the creditor is a party too: " & authority(creditor).detail
  let other = authority(outsider)
  doAssert other.status == rdMissing and "does not name you" in other.detail, other.detail
  doAssert other.remedy.len > 0
  doAssert id(debtor)[0 ..< 12] notin other.detail and id(creditor)[0 ..< 12] notin other.detail,
           "the grade names no one else (inv 9): " & other.detail
  # not asked (no intent to grade against): unknown, never a silent met
  let blank = assessReadiness(sm, probeFromFacts(HostFacts()))
  doAssert blank.item(rqAuthority).status == rdUnknown, blank.item(rqAuthority).detail
  echo "7. split-party graded from the split: debtor and creditor met, anyone else missing, unasked unknown OK"

  # ── 8. only a PAYER is asked for a share: the creditor agrees, and pays nothing (exo-272) ──
  proc itemsFor(k: EncKeys): Readiness =
    assessReadiness(sm, probeFromFacts(HostFacts(contributes: sd.mayContribute(se, names(k)),
                                                 pays: sd.settlesAPart(se, names(k)))))
  proc hasShare(r: Readiness): bool =
    for it in r.items:
      if it.requirement.kind == rqAsset: return true
  doAssert itemsFor(debtor).hasShare(), "a debtor's card asks for their share"
  doAssert not itemsFor(creditor).hasShare(), "the creditor's card does not"
  doAssert hasShare(assessReadiness(sm, probeFromFacts(HostFacts()))), "unasked: the slot shows, unknown — never hidden"
  # the recipient's offers follow the same rule
  proc shareOffered(pays: Eligibility): bool =
    for o in recipientOffers(sm.requirements, @[], sm, pays):
      if o.requirement.kind == rqAsset: return true
  doAssert shareOffered(elYes) and not shareOffered(elNo) and shareOffered(elUnknown)
  echo "8. a share is asked of the people who pay it, never of the creditor OK"

# ── 9–15: a module requirement in three states, and what to install (exo-dcc.10) ──
# Running (it answers muster), installed but not running, not installed — the last two
# from the host's module registry (modules_state.module_record, bounded and cached by the
# host). The driver names the PACKAGE to install, which can differ from the module it
# needs (Monero: the backend, installed by monero_wallet_ui). Muster names it; Basecamp's
# Package Manager installs it, on the person's confirmation (invariant 3).
type Counter = ref object
  n: int
type CountingInvoker = ref object of Invoker
  asked: int
  methods: JsonNode
method methodsOf(inv: CountingInvoker, targetModule: string): JsonNode =
  inc inv.asked
  inv.methods
type Clock = ref object
  t: MonoTime
proc clockOf(c: Clock): proc(): MonoTime {.gcsafe.} = (proc(): MonoTime = c.t)

proc answering(a: ModuleRecordAnswer, c: Counter = nil): ModuleRecordProbe =
  (proc(name: string): ModuleRecordAnswer =
    if c != nil: inc c.n
    a)
proc raising(): ModuleRecordProbe =
  (proc(name: string): ModuleRecordAnswer = raise newException(IOError, "lp_invoke died"))
proc countingRpc(c: Counter): proc(url: string): tuple[ok: bool, chainId: int, detail: string] {.gcsafe.} =
  (proc(url: string): tuple[ok: bool, chainId: int, detail: string] = (inc c.n; (true, 1, "chain 1")))
proc rec(state: string, reason = ""): ModuleRecordAnswer =
  ModuleRecordAnswer(answered: true, known: true, state: state, reason: reason)

let agreeOne = DriverDescriptor(rounds: 1, serializationDomain: "x", finality: finImmediate, threshold: 1)
let backend = req(rqModule, "monero_wallet_backend", install = "monero_wallet_ui")
proc gradeWith(inv: Invoker, records: ModuleRecordProbe, r = backend): ReadinessItem =
  let mm = ActionManifest(declared: true, agreement: agreeOne, requirements: @[r])
  assessReadiness(mm, probeFromFacts(HostFacts(invoker: inv, moduleRecord: records))).item(rqModule)

# ── 9. every grading row ──────────────────────────────────────────────────────
# The registry is asked FIRST, and muster calls into a module only when the host reports
# it `ready`: over lp, a call to a module installed but not loaded blocks for the
# caller's whole deadline (20 s, observed 19.97 s), and lp_get_methods takes none. When
# the registry cannot be asked (the standalone runner bundles no modules_state), muster
# asks the module itself, as before.
block:
  let silent = newLocalInvoker()          # muster's own call finds no methods
  let running = newLocalInvoker()
  running.registerMethods("monero_wallet_backend", %*[{"name": "prepare_send", "isInvokable": true}])
  # ready, and it answers muster: running
  let asked = Counter()
  let r1 = gradeWith(running, answering(rec("ready"), asked))
  doAssert r1.status == rdMet and r1.moduleState == msReady and r1.install == "" and r1.remedy == "", $r1
  doAssert asked.n == 1, "the registry is asked first"
  # anything short of ready: muster never calls into it (it would block for the deadline)
  for a in [rec("unloaded"), rec("loading"), rec("loaded"), rec("stopping"), rec("error"), rec("hibernating"),
            ModuleRecordAnswer(answered: true, known: false)]:
    let inv = CountingInvoker(methods: %*[{"name": "prepare_send"}])
    let r = gradeWith(inv, answering(a))
    doAssert inv.asked == 0, "muster called into a module the host reports " & a.state
    doAssert r.status != rdMet, $r
  # the registry cannot be asked (no modules_state, a failed or timed-out call, a raise):
  # muster asks the module itself — running if it answers...
  for records in [answering(ModuleRecordAnswer(answered: false, detail: "no modules_state")),
                  ModuleRecordProbe(nil), raising()]:
    let up = gradeWith(running, records)
    doAssert up.status == rdMet and up.moduleState == msReady and up.install == "", $up
    # ...and if it does not, missing, and whether it is installed is not known
    let r = gradeWith(silent, records)
    doAssert r.status == rdMissing and r.moduleState == msUnknown, $r
    doAssert r.install == "monero_wallet_ui", "cannot tell → installing may help: " & $r
    doAssert r.detail == "monero_wallet_backend is not loaded (this host cannot say whether it is installed)", r.detail
    doAssert r.remedy == "install monero_wallet_ui from Basecamp's Package Manager", r.remedy
  # null: the host does not know it — not installed (an answer, not a failure)
  let ni = gradeWith(silent, answering(ModuleRecordAnswer(answered: true, known: false)))
  doAssert ni.status == rdMissing and ni.moduleState == msNotInstalled and ni.install == "monero_wallet_ui", $ni
  doAssert ni.detail == "monero_wallet_backend is not installed", ni.detail
  doAssert ni.remedy == "install monero_wallet_ui from Basecamp's Package Manager", ni.remedy
  # installed but not running — and a state this client does not know reads the same
  # (the registry's forward-compatibility rule: an unrecognised state is "not loaded").
  # Basecamp loads a core module when an app that depends on it opens; a restart does not.
  for state in ["unloaded", "hibernating"]:
    let r = gradeWith(running, answering(rec(state)))
    doAssert r.status == rdMissing and r.moduleState == msInstalled and r.install == "", $r
    doAssert r.detail == "monero_wallet_backend is installed but not running", r.detail
    doAssert r.remedy == "start monero_wallet_backend: close and reopen Muster, or open the app that uses it", r.remedy
  # starting: neither met nor missing yet
  for state in ["loading", "loaded"]:
    let r = gradeWith(silent, answering(rec(state)))
    doAssert r.status == rdUnknown and r.moduleState == msStarting and r.install == "", $r
    doAssert r.detail == "monero_wallet_backend is starting", r.detail
    doAssert r.remedy == "wait for monero_wallet_backend to finish starting", r.remedy
  # the host says ready, but muster's own call has not been answered yet (the token
  # handshake is per caller): unknown, never a silent met
  let rs = gradeWith(silent, answering(rec("ready")))
  doAssert rs.status == rdUnknown and rs.moduleState == msReady and rs.install == "", $rs
  doAssert rs.detail == "the host reports monero_wallet_backend ready, but it did not answer muster yet", rs.detail
  doAssert rs.remedy == "reopen this in a moment", rs.remedy
  let st = gradeWith(silent, answering(rec("stopping")))
  doAssert st.status == rdMissing and st.moduleState == msInstalled and st.install == "", $st
  doAssert st.detail == "monero_wallet_backend is stopping", st.detail
  doAssert st.remedy == "start monero_wallet_backend: close and reopen Muster, or open the app that uses it", st.remedy
  let er = gradeWith(silent, answering(rec("error", "exited with code 1")))
  doAssert er.status == rdMissing and er.moduleState == msError and er.install == "", $er
  doAssert er.detail == "monero_wallet_backend failed to load: exited with code 1", er.detail
  doAssert er.remedy == "monero_wallet_backend failed to load: see Basecamp's logs; reinstalling monero_wallet_ui may help", er.remedy
  doAssert gradeWith(silent, answering(rec("error"))).detail == "monero_wallet_backend failed to load"
  # no invoker at all, and no registry: unknown, and installing may help
  let none = gradeWith(nil, ModuleRecordProbe(nil))
  doAssert none.status == rdUnknown and none.moduleState == msUnknown and none.install == "monero_wallet_ui", $none
  doAssert "no host invoker" in none.detail, none.detail
  doAssert none.remedy == "install monero_wallet_ui from Basecamp's Package Manager", none.remedy
  # no invoker, but the registry answers: its answer stands; ready cannot be confirmed
  let noneReady = gradeWith(nil, answering(rec("ready")))
  doAssert noneReady.status == rdUnknown and noneReady.moduleState == msReady and noneReady.install == "", $noneReady
  doAssert gradeWith(nil, answering(ModuleRecordAnswer(answered: true, known: false))).moduleState == msNotInstalled
  # starting and ready-but-silent count as unknown, and nothing short of met is ready
  let both = assessReadiness(ActionManifest(declared: true, agreement: agreeOne,
                                            requirements: @[backend, req(rqModule, "lez_core")]),
                             probeFromFacts(HostFacts(invoker: silent, moduleRecord: answering(rec("loading")))))
  doAssert not both.ready and both.unknown == 2
  echo "9. module grades, registry first: running / not installed / installed / starting / ready-but-silent / stopping / error / cannot say OK"

# ── 10. the package to install: the module's own name unless the driver names another ──
block:
  doAssert req(rqModule, "lez_core").installPackage() == "lez_core"
  doAssert backend.installPackage() == "monero_wallet_ui"
  doAssert backend.name == "monero_wallet_backend" and backend.kind == rqModule
  let own = gradeWith(newLocalInvoker(), answering(ModuleRecordAnswer(answered: true, known: false)),
                      req(rqModule, "lez_core"))
  doAssert own.install == "lez_core" and own.remedy == "install lez_core from Basecamp's Package Manager", $own
  echo "10. install defaults to the module's own name; a driver may name the package that provides it OK"

# ── 11. the JSON the card reads ───────────────────────────────────────────────
block:
  let mm = ActionManifest(declared: true, agreement: agreeOne,
    requirements: @[backend, req(rqModule, "lez_core"), req(rqInfra, "rpc"),
                    req(rqAuthority, "roster-member", rpContributor)])
  let mj = mm.toJson()
  doAssert mj["requirements"][0]["install"].getStr() == "monero_wallet_ui", $mj["requirements"][0]
  doAssert mj["requirements"][1]["install"].getStr() == "lez_core", $mj["requirements"][1]
  doAssert not mj["requirements"][2].hasKey("install") and not mj["requirements"][3].hasKey("install")
  let j = assessReadiness(mm, probeFromFacts(HostFacts(invoker: newLocalInvoker(),
    moduleRecord: answering(ModuleRecordAnswer(answered: true, known: false))))).toJson()
  for it in j["items"]:
    if it["kind"].getStr() == "module":
      doAssert it["moduleState"].getStr() == "not-installed", $it
      doAssert it["install"].getStr() in ["monero_wallet_ui", "lez_core"], $it
      for k in ["kind", "name", "party", "needs", "status", "detail", "remedy"]: doAssert it.hasKey(k), k
    else:
      doAssert not it.hasKey("moduleState") and not it.hasKey("install"), $it
  # an installed module offers no install
  let inst = assessReadiness(ActionManifest(declared: true, agreement: agreeOne, requirements: @[backend]),
    probeFromFacts(HostFacts(invoker: newLocalInvoker(), moduleRecord: answering(rec("unloaded"))))).toJson()
  doAssert inst["items"][0]["moduleState"].getStr() == "installed" and inst["items"][0]["install"].getStr() == ""
  echo "11. JSON: module items carry moduleState + install, the manifest's module requirements their package OK"

# ── 12. modules_state's answer as it arrives over lp_* ────────────────────────
block:
  let n = parseModuleRecord(newJNull())
  doAssert n.answered and not n.known, "null = the host does not know it: not installed, not a failure"
  let r = parseModuleRecord(%*{"module": "lez_core", "state": "error", "reason": "exited", "path": "/m",
                               "type": "core", "version": "0.5.0", "dependencies": [], "dependents": [],
                               "loadedAt": 0, "seq": 7})
  doAssert r.answered and r.known and r.state == "error" and r.reason == "exited", $r
  doAssert parseModuleRecord(%*{"module": "x", "state": "unloaded", "reason": nil}).reason == ""
  doAssert parseModuleRecord(%"{\"module\":\"x\",\"state\":\"ready\"}").state == "ready", "a JSON string is unwrapped"
  doAssert parseModuleRecord(%"null").answered and not parseModuleRecord(%"null").known
  # the value as a host may wrap it ({"result": …}, logoscore's {"status":"ok","result": …})
  let wrapped = parseModuleRecord(%*{"result": nil})
  doAssert wrapped.answered and not wrapped.known, $wrapped
  doAssert parseModuleRecord(%*{"status": "ok", "result": {"module": "x", "state": "loading"}}).state == "loading"
  doAssert not parseModuleRecord(%*{"result": 3}).answered
  # "" is the old failure sentinel (a call that raced its token), never "not installed"
  for v in [%"", %*{"success": false}, %*[1, 2], newJInt(3), JsonNode(nil)]:
    let a = parseModuleRecord(v)
    doAssert not a.answered and a.detail.len > 0, $v
  echo "12. module_record: null is not installed, a record its state, anything else cannot say OK"

# ── 12b. a null is "not installed" only from a registry that knows muster itself ──
# An unknown method answers null on every transport, so an older modules_state without
# module_record would read every module as not installed; one not yet fed knows nothing.
# A registry that knows muster_module — loaded, since it is asking — is answering for real.
block:
  proc registry(known: seq[string], c: Counter): ModuleRecordProbe =
    (proc(name: string): ModuleRecordAnswer =
      inc c.n
      if name in known: ModuleRecordAnswer(answered: true, known: true, state: "ready")
      else: ModuleRecordAnswer(answered: true, known: false))
  let c1 = Counter()
  let real = selfChecked(registry(@["muster_module"], c1), "muster_module")
  let absent = real("monero_wallet_backend")
  doAssert absent.answered and not absent.known and c1.n == 2, "null stands, after asking about muster itself"
  discard real("muster_module")
  doAssert c1.n == 3, "a record needs no check"
  let c2 = Counter()
  let blind = selfChecked(registry(@[], c2), "muster_module")
  let b = blind("monero_wallet_backend")
  doAssert not b.answered and "muster_module" in b.detail, $b
  let c3 = Counter()
  let r = selfChecked(registry(@["lez_core"], c3), "muster_module")("lez_core")
  doAssert r.known and c3.n == 1, "a record is not second-guessed"
  echo "12b. a null counts as not installed only from a registry that knows muster itself OK"

# ── 13. every probe is cached per module name, so a poll never stalls the module ──
block:
  let clock = Clock(t: getMonoTime())
  let c = Counter()
  let cached = cachedRecords(answering(rec("unloaded"), c), initDuration(seconds = 5), now = clockOf(clock))
  doAssert cached("lez_core").state == "unloaded" and cached("lez_core").state == "unloaded"
  doAssert c.n == 1, "asked once within the window: " & $c.n
  discard cached("monero_wallet_backend")
  doAssert c.n == 2, "per module name"
  clock.t = clock.t + initDuration(seconds = 6)
  discard cached("lez_core")
  doAssert c.n == 3, "asked again once the window has passed"
  # a registry that cannot be asked is not asked again for longer, about any module: the
  # standalone runner has none, and must not pay the budget on every poll
  let f = Counter()
  let failing = cachedRecords(answering(ModuleRecordAnswer(answered: false, detail: "timed out"), f),
                              initDuration(seconds = 5), initDuration(seconds = 60), clockOf(clock))
  discard failing("x"); discard failing("x"); discard failing("y")
  doAssert f.n == 1, "unavailable: asked once for every module: " & $f.n
  doAssert not failing("z").answered and failing("z").detail == "timed out"
  clock.t = clock.t + initDuration(seconds = 30)
  discard failing("x")
  doAssert f.n == 1, "still within the minute"
  clock.t = clock.t + initDuration(seconds = 31)
  discard failing("x")
  doAssert f.n == 2, "asked again after the minute"
  doAssert RegistryDownWindow >= initDuration(seconds = 60) and RegistryWindow <= initDuration(seconds = 5)
  doAssert RegistryBudgetMs <= 500, "modules_state answers in milliseconds: a short budget"
  # the module's own methods (lp_get_methods), the same way
  let inner = CountingInvoker(methods: %*[{"name": "open"}])
  let inv = newCachedInvoker(inner, initDuration(seconds = 5), clockOf(clock))
  doAssert inv.methodsOf("lez_core").len == 1 and inv.methodsOf("lez_core").len == 1
  doAssert inner.asked == 1
  discard inv.methodsOf("delivery_module")
  doAssert inner.asked == 2
  clock.t = clock.t + initDuration(seconds = 6)
  discard inv.methodsOf("lez_core")
  doAssert inner.asked == 3
  echo "13. module_record and methodsOf cached per module name for a window OK"

# ── 14. a kind's needs (the composer's "Settles on" list): its instance-side modules ──
block:
  let silent = newLocalInvoker()
  let rpcAsked = Counter()
  var f = HostFacts(invoker: silent, moduleRecord: answering(ModuleRecordAnswer(answered: true, known: false)),
                    rpcUrl: "http://rpc")
  f.rpcProbe = countingRpc(rpcAsked)   # an environment need is the card's, never the list's
  let p = probeFromFacts(f)
  let mm = ActionManifest(declared: true, agreement: agreeOne,
    requirements: @[req(rqEnvironment, "eip155:1"), req(rqInfra, "rpc"), backend,
                    req(rqModule, "pay_module", rpPayer),
                    req(rqModule, "proposer_only", rpProposer, need(mcCapability, "x", "module")),
                    req(rqAuthority, "roster-member", rpContributor)])
  let needs = kindNeeds(mm, p)
  doAssert needs.kind == JArray and needs.len == 2, $needs
  doAssert needs[0]["name"].getStr() == "monero_wallet_backend" and needs[1]["name"].getStr() == "pay_module"
  for n in needs:
    for k in ["kind", "name", "party", "needs", "status", "detail", "remedy", "moduleState", "install"]:
      doAssert n.hasKey(k), k & " in " & $n
    doAssert n["kind"].getStr() == "module" and n["status"].getStr() == "missing" and
             n["moduleState"].getStr() == "not-installed"
  doAssert needs[0]["install"].getStr() == "monero_wallet_ui" and needs[1]["install"].getStr() == "pay_module"
  doAssert rpcAsked.n == 0
  # none: undeclared, or declaring no module
  doAssert kindNeeds(ActionManifest(declared: false), p).len == 0
  doAssert kindNeeds(ActionManifest(declared: true, agreement: agreeOne,
                                    requirements: @[req(rqInfra, "rpc")]), p).len == 0
  doAssert kindNeeds(newUnsupportedDriver("safe").manifest(Effect()), p).len == 0
  # every kind's manifest, on the empty effect the composer has before any proposal, grades
  # without a raise — and only the LEZ split names a module (lez_core) up front
  for k in Kinds:
    let n = kindNeeds(fixtureDriver(k.kind).manifest(Effect()), p)
    doAssert n.kind == JArray, k.kind
    if k.kind == "lez-split":
      doAssert n.len == 1 and n[0]["name"].getStr() == "lez_core" and n[0]["install"].getStr() == "lez_core", $n
  # ...and the split as the module builds it for the list: on no chain yet
  let lezAny = newSplitDriver(LezSplitFamily, "", @["aa"])
  doAssert kindNeeds(lezAny.manifest(Effect()), p)[0]["name"].getStr() == "lez_core"
  echo "14. kindNeeds: a kind's instance-side module needs, graded like the card; [] when it declares none OK"

# ── 15. coordinate_drivers rows carry those needs ─────────────────────────────
block:
  for row in kindsJson(@["safe"]):
    doAssert row.hasKey("needs") and row["needs"].kind == JArray and row["needs"].len == 0, $row
  let lezNeed = %*[{"kind": "module", "name": "lez_core", "moduleState": "not-installed", "install": "lez_core"}]
  let rows = kindsJson(@["safe"], proc(kind: string): JsonNode =
    if kind == "safe": raise newException(ValueError, "no account")
    if kind == "lez-split": lezNeed else: newJArray())
  for row in rows:
    doAssert row["needs"].kind == JArray, $row
    if row["kind"].getStr() == "lez-split": doAssert row["needs"] == lezNeed
    else: doAssert row["needs"].len == 0, "a kind whose needs cannot be built names none: " & $row
  echo "15. coordinate_drivers rows carry each kind's graded module needs ([] when none, never a raise) OK"

# ── 16. no registry to ask: muster calls only the modules it declares ──────────
# Without modules_state (the standalone runner, or a registry the access policy denies)
# muster cannot tell an absent module from a stopped one, and a call to one that is not
# running blocks for lp's whole deadline: measured 20 s in the runner for a module it does
# not bundle. The modules muster declares are loaded by the host before muster, so a call to
# one answers at once; any other module grades unknown, with the install offered, uncalled.
block:
  let backend = req(rqModule, "monero_wallet_backend", install = "monero_wallet_ui")
  let inv = CountingInvoker(methods: newJArray())
  let declared = proc(name: string): bool {.gcsafe.} = name in ["lez_core", "delivery_module"]
  let p = probeFromFacts(HostFacts(invoker: inv, moduleRecord: answering(unanswered("no registry")),
                                   callableWithoutRegistry: declared))
  let g = p.moduleLoaded("monero_wallet_backend")
  doAssert inv.asked == 0, "an undeclared module is never called without a registry: asked " & $inv.asked
  doAssert g.status == rdUnknown and g.state == msUnknown, $g
  doAssert "cannot say" in g.detail, g.detail
  let r = assessReadiness(ActionManifest(declared: true, agreement: agreeOne, requirements: @[backend]), p)
  doAssert r.items[0].install == "monero_wallet_ui" and r.unknown == 1, $r.items[0]
  # a declared module is still asked, and a running one reads met
  let inv2 = CountingInvoker(methods: %*[{"name": "transfer"}])
  let p2 = probeFromFacts(HostFacts(invoker: inv2, moduleRecord: answering(unanswered("no registry")),
                                    callableWithoutRegistry: declared))
  doAssert p2.moduleLoaded("lez_core").status == rdMet and inv2.asked == 1
  # with a registry that answers, the predicate is not consulted: the registry decides
  let inv3 = CountingInvoker(methods: %*[{"name": "open"}])
  let p3 = probeFromFacts(HostFacts(invoker: inv3, moduleRecord: answering(rec("ready")),
                                    callableWithoutRegistry: declared))
  doAssert p3.moduleLoaded("monero_wallet_backend").status == rdMet and inv3.asked == 1
  echo "16. no registry: only declared modules are called; any other grades unknown, install offered, uncalled OK"

# ── 16b. the remedy for an installed module says what can actually start it ──────
# Measured in Basecamp 0.3.2: reopening Muster starts the modules Muster declares, and
# no others; a relaunch starts nothing. So "close and reopen Muster" is offered only for
# a declared module. Any other is started by the app that uses it, or by hand in
# Basecamp's Modules tab. A module the host reports ready but that never answers Muster
# (seen for an undeclared module, five minutes running) is not told to "reopen this".
block:
  let declared = proc(name: string): bool {.gcsafe.} = name in ["lez_core"]
  let silent = CountingInvoker(methods: newJArray())
  proc itemOf(name: string, state: string): ReadinessItem =
    let m = ActionManifest(declared: true, agreement: agreeOne, requirements: @[req(rqModule, name)])
    assessReadiness(m, probeFromFacts(HostFacts(invoker: silent, moduleRecord: answering(rec(state)),
                                                callableWithoutRegistry: declared))).item(rqModule)
  doAssert itemOf("lez_core", "unloaded").remedy == "start lez_core: close and reopen Muster", $itemOf("lez_core", "unloaded")
  let other = itemOf("monero_wallet_backend", "unloaded")
  doAssert other.remedy == "start monero_wallet_backend: open the app that uses it, or load it in Basecamp's Modules tab", other.remedy
  let quiet = itemOf("monero_wallet_backend", "ready")
  doAssert quiet.status == rdUnknown and quiet.moduleState == msReady, $quiet
  doAssert quiet.remedy == "monero_wallet_backend is running but does not answer Muster; Muster may need an update that declares it", quiet.remedy
  doAssert itemOf("lez_core", "ready").remedy == "reopen this in a moment"
  echo "16b. an installed module's remedy names what can start it: Muster for its own, the app or the Modules tab otherwise OK"

echo "readiness_test: all OK"
