## A shared fixture for the split's spec probes (derived-exo-a90): a room of four —
## Alice, who fronted the bill (the creditor); Bob and Carol, who owe her (debtors A and
## B); and Dave, a member the split does not name (the outsider) — over the local
## transport, with the split driver resolving evm-split@eip155:31337 and
## lez-split@lez:testnet. Not a probe itself (no `probe_` prefix).
## Build: see live_room.nim.

import std/[strutils, sequtils]
import ../../src/log/log
import ../../src/transport/transport
import ../../src/crypto/epoch_crypto
import ../../src/crypto/keystore
import ../../src/crypto/curve25519
import ../../src/drivers/driver
import ../../src/drivers/kinds
import ../../src/drivers/split
import ../../src/coordination/session
import ../../src/coordination/intents
import ../../src/coordination/live
import ../../src/coordination/authorship
export log, keystore, curve25519, driver, kinds, split, session, intents, live, authorship

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc key(hex: string): array[32, byte] =
  var h = hex
  if h.startsWith("0x"): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

const Now* = 1_800_000_000'u64
const Ttl* = 3600'i64
const EvmChain* = "eip155:31337"
const LezChain* = "lez:testnet"
const EvmPolicy* = "evm-split@" & EvmChain
const LezPolicy* = "lez-split@" & LezChain
const AlicePayTo* = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

let aliceKs* = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs* = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let carolKs* = newInMemoryKeystore(key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"), seed(3))
let daveKs* = newInMemoryKeystore(key("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(4))

proc idHex*(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let alice* = idHex(aliceKs)
let bob* = idHex(bobKs)
let carol* = idHex(carolKs)
let dave* = idHex(daveKs)
let roster* = @[alice, bob, carol, dave]

let splitFor*: DriverFor = proc(policy: string): Driver =
  if policy == EvmPolicy: newSplitDriver(EvmSplitFamily, EvmChain, roster)
  elif policy == LezPolicy: newSplitDriver(LezSplitFamily, LezChain, roster)
  else: newUnsupportedDriver(policy)

type Room4* = object
  topic*: string
  alice*, bob*, carol*, dave*: CoordinationSession
  seqNo*: uint64

proc newRoom4*(topic: string): Room4 =
  ## Alice founds the room for the other three: one epoch key, granted to each.
  let net = newLocalNetwork()
  let others = @[bobKs, carolKs, daveKs]
  let aliceCrypto = newEpochCrypto(aliceKs, topic, others.mapIt(it.encIdentity()))
  var sessions: seq[CoordinationSession]
  for ks in others:
    let c = newEpochJoiner(ks)
    c.ingestGrant(aliceCrypto.grantFor(0, ks.encIdentity()))
    sessions.add newCoordinationSession(newLocalTransport(net), c, topic)
  Room4(topic: topic, alice: newCoordinationSession(newLocalTransport(net), aliceCrypto, topic),
        bob: sessions[0], carol: sessions[1], dave: sessions[2])

proc sync*(r: Room4) = (r.alice.poll(); r.bob.poll(); r.carol.poll(); r.dave.poll())

proc sessionOf*(r: Room4, who: string): (CoordinationSession, Keystore) =
  case who
  of "alice": (r.alice, Keystore(aliceKs))
  of "bob": (r.bob, Keystore(bobKs))
  of "carol": (r.carol, Keystore(carolKs))
  else: (r.dave, Keystore(daveKs))

proc identityOf*(who: string): string =
  case who
  of "alice": alice
  of "bob": bob
  of "carol": carol
  else: dave

proc propose*(r: var Room4, policy, effectJson: string, ttl = Ttl): string =
  inc r.seqNo
  liveProposeIntent(r.alice, aliceKs, splitFor, policy, effectJson, int64(Now), r.seqNo,
                    account = policy.split('@')[1] & ":alice", ttlSec = ttl)

proc agree*(r: Room4, who, id: string): string =
  let (s, ks) = r.sessionOf(who)
  liveContribute(s, ks, splitFor, id, "", "", LinkContext(account: "probe", slot: "0", expiry: Now + 86_400), Now)

proc partView*(r: Room4, id, who: string): PartView =
  r.sync()
  for v in reduceIntentViews(r.alice.roomEvents(), splitFor):
    if v.id == id:
      for p in v.parts:
        if p.part == partName(identityOf(who)): return p

proc stateOf*(r: Room4, id: string): string =
  r.sync()
  intentState(r.alice.roomEvents(), splitFor, id)
