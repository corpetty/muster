## Shared fixture for the exo-ef1 probes: a REAL two-member room over
## LocalTransport, driven through coordination/live.nim — the exact propose /
## contribute code the hosted coordinate_* methods run. Real drivers only (the anvil
## Safe fixture and an Ed25519 threshold roster of the room's own members), never a
## mocked Driver or Transport (working agreement). The point of exo-ef1 is that the
## exo-3a1 probes tested a model this path never called; these drive the path.
##
## Build (every exo-ef1 probe): the hosted path links secp256k1 + libsodium —
##   nim r -d:release --threads:on $SECP $STINT --passL:"$SODIUM/lib/libsodium.so" \
##     tests/probes/probe_live_<name>.nim          (flags: tests/README.md)

import std/[strutils, tables]
import ../../src/log/log
import ../../src/transport/transport
import ../../src/crypto/epoch_crypto
import ../../src/crypto/secp256k1
import ../../src/crypto/keystore
import ../../src/crypto/binding
import ../../src/crypto/curve25519
import ../../src/drivers/driver
import ../../src/drivers/safe
import ../../src/drivers/threshold
import ../../src/intents/signing_payload
import ../../src/coordination/session
import ../../src/coordination/intents
import ../../src/coordination/live
import ../../src/coordination/attest
export log, keystore, driver, signing_payload, session, intents, live, attest, tables, strutils

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

proc toAddr(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

const SafeAddr* = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
const Now* = 1_800_000_000'u64      ## the probes' wall clock (sign/submit time)
const Ttl* = 3600'i64                ## proposal lifetime

# anvil accounts 0/1 are Safe owners; the Ed25519 halves form the threshold roster.
let aliceKs* = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs* = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))

let safeDrv* = newSafeDriver(chainId = 31337, safe = toAddr(SafeAddr),
  owners = @[toAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
             toAddr("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
             toAddr("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")],
  threshold = 2)
let thrDrv* = newThresholdDriver(@[aliceKs.encIdentity().ed, bobKs.encIdentity().ed], 2)

let liveDriverFor*: DriverFor = proc(kind: string): Driver =
  if kind == "threshold": Driver(thrDrv) else: Driver(safeDrv)

const LivePolicies* = ["safe", "threshold"]

type Room* = object
  topic*: string
  alice*, bob*: CoordinationSession
  seqNo*: uint64

proc newRoom*(topic = "/muster/1/ef1-probe/proto"): Room =
  let net = newLocalNetwork()
  let aliceCrypto = newEpochCrypto(aliceKs, @[bobKs.encIdentity()])
  let bobCrypto = newEpochJoiner(bobKs)
  bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobKs.encIdentity()))
  Room(topic: topic,
       alice: newCoordinationSession(newLocalTransport(net), aliceCrypto, topic),
       bob: newCoordinationSession(newLocalTransport(net), bobCrypto, topic))

proc bindCtx*(): LinkContext = LinkContext(account: SafeAddr, slot: "0", expiry: Now + 86_400)

proc accountFor*(r: Room, policy: string): string =
  if policy == "safe": SafeAddr else: r.topic

proc effectFor*(policy: string, n: int, extra = ""): string =
  ## A representative effect per policy; `extra` splices more JSON members in.
  let tail = (if extra.len > 0: "," & extra else: "")
  if policy == "safe":
    "{\"to\":\"0x1111111111111111111111111111111111111111\",\"value\":" & $n &
      ",\"nonce\":0" & tail & "}"
  else:
    "{\"effect\":\"statement\",\"text\":\"probe " & $n & "\"" & tail & "}"

proc propose*(r: var Room, policy, effectJson: string, nowSec = Now,
              ttl = Ttl): string =
  inc r.seqNo
  liveProposeIntent(r.alice, aliceKs, liveDriverFor, policy, effectJson, int64(nowSec),
                    r.seqNo, account = r.accountFor(policy), ttlSec = ttl)

proc approveAs*(r: Room, who: string, id: string, nowSec = Now): string =
  ## An IN-APP approval (empty signature → the keystore signs), as alice or bob.
  let (s, ks) = (if who == "alice": (r.alice, aliceKs) else: (r.bob, bobKs))
  liveContribute(s, ks, liveDriverFor, id, "", "", bindCtx(), nowSec)

proc events*(r: Room): seq[Event] =
  r.alice.poll(); r.bob.poll()
  r.alice.log.allEvents()

proc attestEventsFor*(evs: seq[Event], id: string): seq[Event] =
  for e in evs:
    if e.key.startsWith("intent/" & id & "/attest/"): result.add e

proc sigEventsFor*(evs: seq[Event], id: string): seq[Event] =
  for e in evs:
    if e.key.startsWith("intent/" & id & "/sig/"): result.add e

proc countedApprovals*(evs: seq[Event], id: string): int =
  ## Distinct approvals the fold COUNTS toward the threshold.
  let folded = reduceIntents(evs, liveDriverFor)
  if id notin folded: return 0
  folded[id].collection.acceptedThisRound
