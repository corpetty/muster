## A shared fixture for the room map's spec probes (derived-exo-dde): real sessions over
## the local transport, real epoch crypto, the real join handshake, and real drivers — a
## Safe (2 of 3, owners anvil 0, 1, 2) and the split (evm-split) — driven through the
## hosted propose / contribute / reannounce path (coordination/live.nim). Alice founds the
## room with Bob; Carol, and in one story Dave, join at a chosen point. Every event that can
## carry text carries a unique marker, so a probe can ask of any member's map, event by
## event, whether that event's content reached it.
## Not a probe itself (no `probe_` prefix). Build: see live_room.nim.

import std/[strutils, sequtils, tables, json, sets, algorithm]
import ./split_room
import ../../src/transport/transport
import ../../src/crypto/epoch_crypto
import ../../src/crypto/binding
import ../../src/crypto/secp256k1
import ../../src/drivers/safe
import ../../src/coordination/attest
import ../../src/coordination/accounts
import ../../src/coordination/flow
import ../../src/coordination/room_graph
export split_room, room_graph, flow, attest, accounts, tables, json, sets, algorithm, transport, epoch_crypto

const SafeAddr* = "0x5fbdb2315678afecb367f032d93f642f64180aa3"
const SafeChain* = "eip155:31337"

proc hex0x(a: Address): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in a: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc addr20(hex: string): Address =
  var h = hex
  if h.startsWith("0x"): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

let safeDrv* = newSafeDriver(chainId = 31337, safe = addr20(SafeAddr),
  owners = @[aliceKs.address(), bobKs.address(), addr20("0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc")],
  threshold = 2)

let mapFor*: DriverFor = proc(policy: string): Driver =
  if policy == "safe" or policy.startsWith("safe@"): Driver(safeDrv) else: splitFor(policy)

type
  Family* = enum famSafe = "safe", famSplit = "split"
  MapRoom* = object
    topic*: string
    net*: LocalNetwork
    alice*, bob*: CoordinationSession
    joiners*: Table[string, CoordinationSession]   ## "carol", "dave" once joined
    seqNo*: uint64
    markers*: Table[string, string]                ## event id → the unique marker its content carries

proc newMapRoom*(topic: string): MapRoom =
  ## Alice founds the room for Bob alone: epoch 0's key is granted to him.
  let net = newLocalNetwork()
  let aliceCrypto = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity()])
  let bobCrypto = newEpochJoiner(bobKs)
  bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobKs.encIdentity()))
  MapRoom(topic: topic, net: net,
          alice: newCoordinationSession(newLocalTransport(net), aliceCrypto, topic),
          bob: newCoordinationSession(newLocalTransport(net), bobCrypto, topic))

proc members*(r: MapRoom): seq[(string, CoordinationSession)] =
  result = @[("alice", r.alice), ("bob", r.bob)]
  for who in ["carol", "dave"]:
    if who in r.joiners: result.add (who, r.joiners[who])

proc sync*(r: MapRoom) =
  for (_, s) in r.members: s.poll()

proc ksFor*(who: string): Keystore =
  case who
  of "alice": aliceKs
  of "bob": bobKs
  of "carol": carolKs
  else: daveKs

proc sess*(r: MapRoom, who: string): CoordinationSession =
  if who == "alice": r.alice elif who == "bob": r.bob else: r.joiners[who]

proc mark*(r: var MapRoom, s: CoordinationSession, key, marker: string) =
  ## Record the marker of the event this session last published under `key`.
  for e in s.log.allEvents():
    if e.key == key: r.markers[eventId(e)] = marker

proc say*(r: var MapRoom, who, marker: string) =
  ## A chat line whose body is `marker`, authored and signed as the module posts it.
  inc r.seqNo
  let (_, m) = newMessageEvent(idHex(ksFor(who)), int64(Now) + int64(r.seqNo), marker, r.seqNo)
  r.sess(who).publishAuthored(ksFor(who), m)
  r.mark(r.sess(who), m.key, marker)
  r.sync()

proc discloseSafe*(r: var MapRoom, who, marker: string) =
  ## The Safe, disclosed into the room; its label is the marker.
  let a = RoomAccount(family: "evm.safe", chain: SafeChain, address: SafeAddr, label: marker,
                      signers: @[aliceKs.address(), bobKs.address(), addr20("0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc")].mapIt(hex0x(it)),
                      threshold: 2, id: accountId(SafeChain, SafeAddr))
  let e = accountDiscloseEvent(a, idHex(ksFor(who)))
  r.sess(who).publishAuthored(ksFor(who), e)
  r.mark(r.sess(who), e.key, marker)
  r.sync()

proc proposeSafe*(r: var MapRoom, marker: string): string =
  ## A Safe payment whose memo is the marker.
  inc r.seqNo
  let effect = "{\"to\":\"0x1111111111111111111111111111111111111111\",\"value\":7,\"nonce\":0,\"memo\":\"" & marker & "\"}"
  result = liveProposeIntent(r.alice, aliceKs, mapFor, "safe", effect, int64(Now), r.seqNo,
                             account = SafeAddr, ttlSec = Ttl)
  r.mark(r.alice, "intent/" & result & "/propose", marker)
  r.sync()

proc proposeSplit*(r: var MapRoom, marker: string): string =
  ## A split of 900 wei Alice fronted, owed by Bob and Carol; its memo is the marker.
  inc r.seqNo
  let effect = splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                               evenShares("900", alice, @[bob, carol], creditorShares = false), marker)
  result = liveProposeIntent(r.alice, aliceKs, mapFor, EvmPolicy, effect, int64(Now), r.seqNo,
                             account = EvmChain & ":alice", ttlSec = Ttl)
  r.mark(r.alice, "intent/" & result & "/propose", marker)
  r.sync()

proc approve*(r: var MapRoom, who, id: string) =
  ## An in-app approval (the keystore signs; the attestation follows), as the module does.
  discard liveContribute(r.sess(who), ksFor(who), mapFor, id, "", "",
                         LinkContext(account: "probe", slot: "0", expiry: Now + 86_400), Now)
  r.sync()

proc settleSafe*(r: var MapRoom, id, marker: string) =
  ## The Safe submitted and final; the chain reference is the marker.
  r.alice.publish(submitEvent(id, chainRef = marker))
  r.alice.publish(finalEvent(id, chainRef = marker & "f"))
  r.mark(r.alice, "intent/" & id & "/submit", marker)
  r.mark(r.alice, "intent/" & id & "/final", marker & "f")
  r.sync()

proc payPart*(r: var MapRoom, who, id, marker: string) =
  ## `who` reports paying their share; the transaction reference is the marker.
  let e = partEvent(id, partName(idHex(ksFor(who))), "settled", idHex(ksFor(who)), marker)
  r.sess(who).publishAuthored(ksFor(who), e)
  r.mark(r.sess(who), e.key, marker)
  r.sync()

proc confirmPart*(r: var MapRoom, payer, id, marker: string) =
  ## Alice, the creditor, confirms a payer's part from her own read.
  let e = partEvent(id, partName(idHex(ksFor(payer))), "confirmed", alice, marker)
  r.alice.publishAuthored(aliceKs, e)
  r.mark(r.alice, e.key, marker)
  r.sync()

proc join*(r: var MapRoom, who: string, reannounce: bool) =
  ## `who` asks to join and Alice admits them: the room re-keys forward. With
  ## `reannounce`, Alice re-publishes every open intent under the new epoch.
  let s = newCoordinationSession(newLocalTransport(r.net), newEpochJoiner(ksFor(who)), r.topic)
  s.requestJoin(ksFor(who).joinRequestFor(r.topic, high(uint64)))
  r.alice.poll()
  r.alice.admitAs(aliceKs, ksFor(who).encIdentity())   # its membership record signed by alice (exo-045)
  r.joiners[who] = s
  r.sync()
  if reannounce:
    discard liveReannounce(r.alice, aliceKs, mapFor, int64(Now), r.seqNo)
    r.sync()

proc memberHex*(m: Member): string =
  const d = "0123456789abcdef"
  for x in m.toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc rosterHex*(s: CoordinationSession): seq[string] =
  for m in s.members(): result.add memberHex(m)

proc mapOf*(r: MapRoom, who: string): RoomGraph =
  ## `who`'s room map, as coordinate_graph builds it: from the authentic events this
  ## member's session decrypted, with the epoch each was opened under.
  let s = r.sess(who)
  s.poll()
  let events = s.roomEvents()
  reduceRoomGraph(events, mapFor, foundersOf(events, s.rosterHex()), idHex(ksFor(who)), s.sealedIn)
