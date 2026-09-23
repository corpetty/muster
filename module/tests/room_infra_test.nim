## The room's infrastructure is dictated by its drivers (exo-428): a room with no
## proposals needs nothing beyond its own transport; a proposal whose driver declares
## an instance-party infra/environment requirement INTRODUCES it, naming itself; an
## undeclared driver shows as undeclared, never guessed; contributor requirements are
## not infrastructure; the fold is order- and duplicate-independent (inv 4). The flow
## view's observer matrix follows the same rule: an RPC provider / chain observer is
## listed only once a proposal names it. Stub drivers + libsodium (flow_test's closure).

import std/[json, algorithm]
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/intents/materialization   # Effect
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/flow
import ../src/coordination/room_infra
import ../src/drivers/safe
import ../src/drivers/threshold
import ../src/crypto/secp256k1
import ../src/crypto/curve25519

# a Safe-shaped stub: declares an RPC + the chain it must serve (as safe.nim does)
type RpcStub = ref object of StubDriver
method manifest(d: RpcStub, effect: Effect): ActionManifest =
  result = ActionManifest(declared: true, agreement: d.descriptor)
  result.requirements.add req(rqEnvironment, "chain:31337")
  result.requirements.add req(rqInfra, "rpc")
  result.requirements.add req(rqAuthority, "safe-owner", rpContributor)
  result.discloses.add row("signed-tx", obRpcProvider)
  result.discloses.add row("effect", obChainObserver)

type Bare = ref object of Driver
method describe(d: Bare): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "bare", finality: finImmediate, threshold: 1)

let drivers: DriverFor = proc(kind: string): Driver =
  case kind
  of "safe": RpcStub(descriptor: newStubDriver(finality = finExternal).descriptor, verifyResult: true)
  of "bare": Bare()
  else: newStubDriver()   # threshold-like: room-native, needs no infrastructure

proc proposal(effect, policy: string): seq[Event] =
  let id = intentIdFor(effect, policy)
  @[proposeEvent(id, effect), policyDeclEvent(id, policy)]

let (_, msg) = newMessageEvent("alice", 1, "hi", 1)
let decide = proposal("""{"statement":"lunch at noon"}""", "threshold")
let pay1 = proposal("""{"to":"0xabc","value":5}""", "safe")
let pay2 = proposal("""{"to":"0xdef","value":7}""", "safe")
let odd = proposal("""{"x":1}""", "bare")

proc keys(ns: seq[InfraNeed]): seq[string] =
  for n in ns:
    result.add(if n.declared: $n.requirement.kind & ":" & n.requirement.name else: "undeclared")

block:
  doAssert roomInfraNeeds(@[msg], drivers).len == 0
  doAssert roomInfraNeeds(@[msg] & decide, drivers).len == 0,
    "a room-native decision introduces no infrastructure"
  let m = reduceFlow(@[msg] & decide, drivers, @["alice"]).observerMatrix(
    introducedObservers(@[msg] & decide, drivers))
  doAssert m.hasKey("room-member") and m.hasKey("store-node")
  doAssert not m.hasKey("rpc-provider") and not m.hasKey("chain-observer"), $m
  echo "1. a room that talks or decides needs no RPC, lists no RPC provider OK"

block:
  let ev = @[msg] & decide & pay1
  let ns = roomInfraNeeds(ev, drivers)
  doAssert ns.keys == @["environment:chain:31337", "infra:rpc"], $ns.keys
  for n in ns:
    doAssert n.introducedBy == @[(intentIdFor("""{"to":"0xabc","value":5}""", "safe"), "safe")]
  doAssert "authority:safe-owner" notin ns.keys, "a contributor's key is not infrastructure"
  let obs = introducedObservers(ev, drivers)
  doAssert obRpcProvider in obs and obChainObserver in obs
  let m = reduceFlow(ev, drivers, @["alice"]).observerMatrix(obs)
  doAssert m.hasKey("rpc-provider") and m["rpc-provider"].len == 0,
    "introduced by the proposal, but nothing has reached it yet"
  echo "2. a Safe proposal introduces the RPC + its chain, naming itself OK"

block:
  let ns = roomInfraNeeds(@[msg] & pay1 & pay2, drivers)
  doAssert ns.len == 2
  for n in ns: doAssert n.introducedBy.len == 2, "two proposals, one need, both named"
  echo "3. one need per requirement, every introducing proposal named OK"

block:
  let ns = roomInfraNeeds(@[msg] & odd, drivers)
  doAssert ns.keys == @["undeclared"]
  doAssert obChainObserver in introducedObservers(@[msg] & odd, drivers)
  echo "4. an undeclared driver is shown as undeclared, never guessed away OK"

block:
  let ev = @[msg] & decide & pay1 & pay2 & odd
  var shuffled = ev.reversed() & pay1 & msg
  doAssert roomInfraNeeds(ev, drivers).keys == roomInfraNeeds(shuffled, drivers).keys
  doAssert introducedObservers(ev, drivers).sorted == introducedObservers(shuffled, drivers).sorted
  var a, b: seq[string]
  for n in roomInfraNeeds(ev, drivers): a.add $n.introducedBy
  for n in roomInfraNeeds(shuffled, drivers): b.add $n.introducedBy
  doAssert a == b
  echo "5. reorder + duplicate → identical needs (inv 4) OK"

# ── the REAL drivers: Safe introduces the RPC + its chain, threshold introduces nothing.
# Guards the manifests this panel is read from — if safe.nim stopped declaring its RPC,
# the room would stop showing the connection the settle path depends on.
block:
  proc mkAddr(n: byte): Address = (for i in 0 ..< 20: result[i] = n)
  proc ed(n: byte): Ed25519Pub = (for i in 0 ..< 32: result[i] = n)
  let real: DriverFor = proc(kind: string): Driver =
    if kind == "safe": newSafeDriver(chainId = 31337, safe = mkAddr(9),
                                     owners = @[mkAddr(1), mkAddr(2), mkAddr(3)], threshold = 2)
    else: newThresholdDriver(@[ed(1), ed(2)], 2)
  doAssert roomInfraNeeds(@[msg] & decide, real).len == 0
  doAssert obRpcProvider notin introducedObservers(@[msg] & decide, real)
  let ks = roomInfraNeeds(@[msg] & decide & pay1, real).keys
  doAssert "infra:rpc" in ks and "environment:chain:31337" in ks, $ks
  doAssert obRpcProvider in introducedObservers(@[msg] & decide & pay1, real)
  echo "6. the real Safe driver introduces the RPC; the real threshold driver nothing OK"

echo "room_infra_test: all OK"
