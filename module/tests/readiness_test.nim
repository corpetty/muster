## Readiness (exo-002.2): one instance grading a real driver's manifest with the SAME
## probe the module builds from its facts. The done-when: a Safe intent on an instance
## without an RPC reports infra:missing with the remedy, and a non-owner reports
## authority:missing; unknown is first-class, never a silent met; undeclared is not
## ready. Needs the secp closure (SafeDriver) + libsodium (Ed25519) — see tests/README.md.

import std/[json, strutils]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/threshold
import ../src/drivers/manifest
import ../src/coordination/readiness
import ../src/coordination/invoker
import ../src/crypto/secp256k1
import ../src/crypto/curve25519

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

# ── 1. no RPC + a non-owner: infra missing (with remedy), authority missing, env unknown ──
block:
  let f = HostFacts(rpcUrl: "", expectedChainId: 31337, myAddress: mkAddr(7), safeOwners: owners)
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert r.declared and not r.ready
  doAssert r.item(rqInfra).status == rdMissing and "set_setting rpc" in r.item(rqInfra).remedy
  doAssert r.item(rqAuthority).status == rdMissing and "Safe owner" in r.item(rqAuthority).detail
  doAssert r.item(rqEnvironment).status == rdUnknown, "no RPC → the chain cannot be probed → unknown, not met"
  doAssert r.unknown == 1
  echo "1. no RPC + non-owner: infra missing (remedy names set_setting rpc), authority missing, env UNKNOWN OK"

# ── 2. an owner with an RPC serving the right chain: ready ────────────────────────
block:
  var f = HostFacts(rpcUrl: "http://rpc", expectedChainId: 31337, myAddress: mkAddr(2), safeOwners: owners)
  f.rpcProbe = proc(url: string): tuple[ok: bool, chainId: int, detail: string] = (true, 31337, "chain 31337")
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert r.ready and r.unknown == 0, $r.toJson()
  for it in r.items: doAssert it.remedy.len == 0
  echo "2. owner + RPC on the expected chain: ready, no remedies OK"

# ── 3. the RPC serves the WRONG chain: environment missing, named in the detail ─────
block:
  var f = HostFacts(rpcUrl: "http://rpc", expectedChainId: 31337, myAddress: mkAddr(2), safeOwners: owners)
  f.rpcProbe = proc(url: string): tuple[ok: bool, chainId: int, detail: string] = (true, 1, "mainnet")
  let r = assessReadiness(m, probeFromFacts(f))
  doAssert not r.ready
  doAssert r.item(rqEnvironment).status == rdMissing and "chain:31337" in r.item(rqEnvironment).detail
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
    agreement: DriverDescriptor(rounds: 1, serializationDomain: "x", membership: mmAnonymous,
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
  doAssert missing.item(rqModule).status == rdMissing and "install the nope module" in missing.item(rqModule).remedy
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

echo "readiness_test: all OK"
