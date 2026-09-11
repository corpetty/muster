## The generic invoke flow, end to end through a real coordination session (P-D4
## enabler / the "it all works together" proof for exo-fa4). Two instances share an
## encrypted room over LocalTransport; one proposes an invoke intent (call a module
## method), both endorse it over the Ed25519 roster, both converge to executable
## (invariant 4), and then the core executes it via the Invoker seam (a LocalInvoker
## stands in for the target module) and folds the room to final.
##
## This is the coordinate_* surface's algorithm for an invoke-policy intent —
## everything P-D1 (driver), P-D2 (execute), P-D3 (discovery) built, composed over
## the same session round-trip coordination_surface_test exercises for Safe.
## Link flags (curve25519 + libsodium + secp): see tests/README.md.

import std/strutils
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/invoker
import ../src/drivers/driver as drivercore
import ../src/drivers/invoke
import ../src/intents/materialization

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# Two members. Their curve25519 identities are the invoke roster; the keystores back
# the room's epoch crypto. Both enc identities derive from the same seeds, so the
# roster keys match the session members.
let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let aliceMem = encFromSeed(seed(1))
let bobMem   = encFromSeed(seed(2))

# The generic invoke driver: k-of-n over the room roster (k=2 here). The action is
# NOT in the driver — it's in the effect.
let drv = newInvokeDriver(@[aliceMem.identity().ed, bobMem.identity().ed], k = 2)
let foldDrv: DriverFor = proc(kind: string): drivercore.Driver = drv

const effectJson = """{"effect":"invoke","module":"delivery_module","method":"send","args":["/room","hello"]}"""
let id = intentIdFor(effectJson, "invoke")
let mat = canonicalize(drv, effectFromJson(effectJson))

# The shared room.
let net = newLocalNetwork()
let bobEnc = bobKs.encIdentity()
let aliceCrypto = newEpochCrypto(aliceKs, @[bobEnc])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobEnc))
const topic = "/muster/1/invoke-demo/proto"
let alice = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bob = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)

# 1. Alice proposes the invoke intent; Bob recovers the effect from the shared log.
alice.publish(policyDeclEvent(id, "invoke"))
alice.publish(proposeEvent(id, effectJson))
doAssert effectJsonOf(bob.log.allEvents(), id) == effectJson, "Bob recovers the invoke effect"
doAssert intentState(bob.log.allEvents(), foldDrv, id) == "proposed"
echo "1. invoke intent proposed; effect propagates OK"

# 2. Both members endorse over the roster (Ed25519 sig over the materialization).
let aliceSig = toHex(edSign(aliceMem, mat.bytes))
let who0 = contributorOf(drv, effectJson, aliceSig)
doAssert who0.len > 0, "alice's endorsement identifies a roster member"
alice.publish(contributeEvent(id, who0, aliceSig))
doAssert intentState(alice.log.allEvents(), foldDrv, id) == "collecting"

let bobSig = toHex(edSign(bobMem, mat.bytes))
let who1 = contributorOf(drv, effectJson, bobSig)
doAssert who1.len > 0 and who1 != who0, "bob is a distinct roster member"
bob.publish(contributeEvent(id, who1, bobSig))
let aState = intentState(alice.log.allEvents(), foldDrv, id)
let bState = intentState(bob.log.allEvents(), foldDrv, id)
doAssert aState == "executable" and bState == "executable", "k-of-n met -> executable both"
doAssert alice.digest() == bob.digest(), "both instances converge (invariant 4)"
echo "2. both endorse -> executable + convergence OK"

# 3. The core executes it (invariant 3): gate (allowlist + capability), invoke via the
#    Invoker seam, fold forward. A LocalInvoker stands in for delivery_module.send.
let inv = newLocalInvoker()
inv.register("delivery_module", "send", proc(argsJson: string): InvokeOutcome {.gcsafe.} =
  InvokeOutcome(ok: true, value: "\"req\""))
let allow = @[AllowEntry(module: "delivery_module", meth: "send")]
let ex = executeInvoke(inv, allow, "delivery_module", "send", """["/room","hello"]""")
doAssert ex.executed, "the executable invoke intent runs: " & ex.reason
doAssert inv.lastArgs == """["/room","hello"]""", "the module received the coordinated args"
alice.publish(submitEvent(id))
alice.publish(finalEvent(id))
doAssert intentState(alice.log.allEvents(), foldDrv, id) == "final" and
         intentState(bob.log.allEvents(), foldDrv, id) == "final",
         "both instances fold to final after execution"
doAssert alice.digest() == bob.digest(), "final state converges too"
echo "3. core executes (allowlist+capability) -> submitted -> final, both converge OK"

# 4. A SECOND, distinct module action over the SAME generic Tier-0 driver (P-D6):
#    the action lives in the effect, so a different module.method needs no new driver
#    code — only a different effect. Its signed bytes differ (invariant 5: the per-
#    (module, method) schemaId separates them), and it coordinates + executes the same
#    way. This is what "a second real Tier-0 driver end-to-end" means: genericity, not
#    a delivery-specific path.
block:
  const voteJson = """{"effect":"invoke","module":"vote_module","method":"cast","args":["prop-1",1]}"""
  let vid = intentIdFor(voteJson, "invoke")
  let vmat = canonicalize(drv, effectFromJson(voteJson))
  doAssert vmat.bytes != mat.bytes,
    "a different action canonicalizes to different signed bytes (invariant 5 domain separation)"
  doAssert vid != id, "a distinct content-addressed intent"

  alice.publish(policyDeclEvent(vid, "invoke"))
  alice.publish(proposeEvent(vid, voteJson))
  doAssert effectJsonOf(bob.log.allEvents(), vid) == voteJson, "Bob recovers the second action's effect"

  let vaSig = toHex(edSign(aliceMem, vmat.bytes))
  let vbSig = toHex(edSign(bobMem, vmat.bytes))
  alice.publish(contributeEvent(vid, contributorOf(drv, voteJson, vaSig), vaSig))
  bob.publish(contributeEvent(vid, contributorOf(drv, voteJson, vbSig), vbSig))
  doAssert intentState(alice.log.allEvents(), foldDrv, vid) == "executable" and
           intentState(bob.log.allEvents(), foldDrv, vid) == "executable",
           "the second action reaches executable over the same driver"

  let vinv = newLocalInvoker()
  vinv.register("vote_module", "cast", proc(argsJson: string): InvokeOutcome {.gcsafe.} =
    InvokeOutcome(ok: true, value: "true"))
  let vallow = @[AllowEntry(module: "vote_module", meth: "cast")]
  let vex = executeInvoke(vinv, vallow, "vote_module", "cast", """["prop-1",1]""")
  doAssert vex.executed, "the second module action runs too: " & vex.reason
  doAssert vinv.lastArgs == """["prop-1",1]""", "vote_module received the coordinated args"
  echo "4. a second, distinct module action coordinates + executes over the same Tier-0 driver OK"

echo "coordination_invoke_test: the invoke flow works end to end over a real session — all OK"
