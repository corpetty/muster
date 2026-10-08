## exo-7b3 — invariant 4 across a restart: a room is rebuilt from log + keys, its
## founding epoch included.
##
## The room's log lives in memory and a relaunch rebuilds it from the store. Epochs 1
## and later come back from the grants sealed to the member (ingestControl). Epoch 0
## is different: coordinate_join founds it with a key no grant ever carries. If a
## restart cannot rebuild that key, the founder loses everything said and proposed
## before the first admit, and nobody else holds it (F-16).
##
## The test runs the room the way the app does. Every member joins by name through
## the hosted join, so each founds its own epoch. Keystores are keyfiles, reopened from
## disk on restart: a restart keeps the keys and nothing else.
##   1. Alice founds the room, posts a message and proposes an intent before anyone joins.
##   2. Bob joins by name and asks to be admitted. Alice admits him, and Bob speaks in epoch 1.
##   3. Alice restarts and catches up from the store. Her fold holds the pre-admit
##      message and intent, and her state equals the state before the restart.
##   4. F-16 still holds. Bob cannot read epoch 0, before or after his own restart.
##      Carol, admitted by the restarted Alice, reads neither epoch 0 nor epoch 1.
##   5. After a replay, nobody already admitted shows as asking to join.
##   6. A restarted member does not announce the join key it announced before, so a
##      store node cannot link one member's launches (exo-661.7, FS-9).
## Needs libsecp256k1 + libsodium (run-suite.sh supplies them).

import std/[os, sequtils, strutils]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/secp256k1
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/sodium
import ../src/drivers/driver as drivercore
import ../src/drivers/safe
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/authorship
import ../src/coordination/live

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc toAddr(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc hex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

const SafeAddr = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
const Now = 1_800_000_000'i64
const topic = "/muster/1/founder-restart/proto"
const Pass = "founder-restart"

let safeDrv = newSafeDriver(chainId = 31337, safe = toAddr(SafeAddr),
  owners = @[toAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
             toAddr("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
             toAddr("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")],
  threshold = 2)
let drvFor: DriverFor = proc(kind: string): drivercore.Driver = safeDrv

# Each member's identity is a keyfile, as the module's is. A restart reopens it.
let dir = getTempDir() / ("muster-founder-restart-" & hex0x(randomBytes(6))[2 .. ^1])
createDir(dir)
proc keystoreOf(who: string): Keystore =
  Keystore(openFileKeystore(dir / (who & ".key"), Pass))

proc beaconsOnTopic(net: LocalNetwork): seq[seq[byte]] =
  for m in newLocalTransport(net).storeQuery(topic):
    if m.payload.len == 33 and m.payload[0] == 0x04'u8: result.add m.payload[1 .. ^1]

var launches, freshKeys = 0
proc join(net: LocalNetwork, ks: Keystore): CoordinationSession =
  ## What coordinate_join builds for a topic it holds no session on, and what it announces.
  ## The store keeps one copy of identical bytes, so a launch that announces a join key
  ## the topic already carries leaves the store's beacon count unchanged.
  let known = net.beaconsOnTopic().len
  result = newCoordinationSession(newLocalTransport(net), newEpochCrypto(ks, topic), topic)
  result.announceBeacon()
  inc launches
  if net.beaconsOnTopic().len == known + 1: inc freshKeys

proc restart(net: LocalNetwork, who: string): (CoordinationSession, Keystore) =
  ## A relaunch: the keyfile reopened from disk, the hosted join, then the store catch-up.
  let ks = keystoreOf(who)
  let s = net.join(ks)
  s.catchUp()
  (s, ks)

proc holds(s: CoordinationSession, body: string): bool =
  reduceMessages(s.roomEvents()).anyIt(it.body == body)

let net = newLocalNetwork()
let ctx = LinkContext(account: topic, slot: "0", expiry: high(uint64))

# ── 1. Alice founds the room and uses it before anyone joins ────────────────────
let aliceKs = keystoreOf("alice")
let alice = net.join(aliceKs)
let aliceId = hex0x(aliceKs.encIdentity().toBytes())
const BeforeAnyone = "said before anyone joined"
let (_, preMsg) = newMessageEvent(aliceId, Now, BeforeAnyone, 1)
alice.publishAuthored(aliceKs, preMsg)
const effectJson = """{"to":"0x1111111111111111111111111111111111111111","value":7,"nonce":0}"""
let intentId = liveProposeIntent(alice, aliceKs, drvFor, "safe", effectJson, Now, 2,
                                 account = SafeAddr)
doAssert intentId.startsWith("0x"), "the proposal is accepted: " & intentId
doAssert alice.holds(BeforeAnyone)
doAssert reduceIntentViews(alice.roomEvents(), drvFor).anyIt(it.id == intentId)
echo "1. Alice founds the room; a message and a proposal before anyone joins OK"

# ── 2. Bob joins by name; Alice admits him; Bob speaks in epoch 1 ────────────────
let bobKs = keystoreOf("bob")
let bob = net.join(bobKs)
bob.requestJoin(bobKs.bindingFor(ctx))
doAssert bobKs.encIdentity() in alice.pendingJoins(), "Alice sees Bob ask"
alice.admit(bobKs.encIdentity())
doAssert bob.members().len == 2, "Bob is admitted"
const AfterBob = "said after Bob was admitted"
let (_, bobMsg) = newMessageEvent(hex0x(bobKs.encIdentity().toBytes()), Now + 10, AfterBob, 1)
bob.publishAuthored(bobKs, bobMsg)
doAssert alice.holds(AfterBob) and bob.holds(AfterBob)
doAssert not bob.holds(BeforeAnyone), "F-16: Bob cannot read what Alice said before admitting him"
echo "2. Bob joins by name and is admitted; he reads epoch 1, not epoch 0 OK"

let digestBefore = alice.digest()

# ── 3. Alice restarts: the room comes back from log + keys, epoch 0 included ─────
let (alice2, aliceKs2) = net.restart("alice")
doAssert alice2.epoch() == 1 and alice2.members().len == 2, "the restart recovers the current epoch"
doAssert alice2.holds(AfterBob), "epoch 1 comes back from its grant"
doAssert alice2.holds(BeforeAnyone),
  "invariant 4: the founder's pre-admit message comes back after a restart"
doAssert effectJsonOf(alice2.roomEvents(), intentId) == effectJson,
  "invariant 4: the founder's pre-admit proposal comes back after a restart"
doAssert reduceIntentViews(alice2.roomEvents(), drvFor).anyIt(it.id == intentId and it.state == "proposed")
doAssert alice2.digest() == digestBefore,
  "invariant 4: state after the restart equals state before it (reduce(log + keys))"
echo "3. Alice restarts; her pre-admit message and proposal come back, state unchanged OK"

# ── 4. F-16 holds: Bob, restarted or not, and Carol cannot read earlier epochs ──
let (bob2, _) = net.restart("bob")
doAssert bob2.holds(AfterBob), "Bob's restart recovers epoch 1"
doAssert not bob2.holds(BeforeAnyone), "F-16: a restarted joiner still cannot read epoch 0"
doAssert effectJsonOf(bob2.roomEvents(), intentId) == "", "F-16: nor the pre-admit proposal"

let carolKs = keystoreOf("carol")
let carol = net.join(carolKs)
carol.requestJoin(carolKs.bindingFor(ctx))
doAssert carolKs.encIdentity() in alice2.pendingJoins(), "the restarted founder sees Carol ask"
alice2.admit(carolKs.encIdentity())
doAssert carol.members().len == 3, "Carol is admitted by the restarted founder"
const AfterCarol = "said after Carol was admitted"
let (_, carolMsg) = newMessageEvent(aliceId, Now + 20, AfterCarol, 3)
alice2.publishAuthored(aliceKs2, carolMsg)
doAssert carol.holds(AfterCarol) and bob2.holds(AfterCarol)
doAssert not carol.holds(BeforeAnyone) and not carol.holds(AfterBob),
  "F-16: Carol reads from her own epoch on, nothing sealed before it"
echo "4. F-16 holds: Bob (restarted) cannot read epoch 0; Carol reads neither 0 nor 1 OK"

# ── 5. A replay shows nobody admitted as asking to join ─────────────────────────
let (alice3, _) = net.restart("alice")
doAssert alice3.members().len == 3 and alice3.holds(BeforeAnyone) and alice3.holds(AfterCarol)
doAssert alice3.pendingJoins().len == 0,
  "a restart replays old join requests; members already admitted are not pending"
echo "5. after a replay, no admitted member shows as asking to join OK"

# ── 6. A restarted member's join key is not the one it announced before ─────────
doAssert launches == 6 and freshKeys == launches,
  "every launch announced a join key the topic never carried (" & $freshKeys & " of " & $launches &
  "): a store node cannot link one member's launches"
echo "6. a restart announces a fresh join key; launches are unlinkable on the topic OK"

removeDir(dir)
echo "founder_restart_test: all OK"
