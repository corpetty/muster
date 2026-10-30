## voice-notes.md §10's claim, held as an oracle for a future derived-exo spec (S5): every
## voice note leaves as two sealed frames of one fixed size, 1 + 24 + 16 + 90,112 = 90,153 B,
## whatever its length, so a store node cannot tell how long it is; and a member folds it back
## whole.
##
## STEPPER: one state per case, chained case -> case+1. Cases are
##   durations {0.5, 1, 10, 30, 59.98, 60 s} x heads {0, 1, 8} x epoch {0, 1}
## (36). Each builds a REAL room: sessions over LocalTransport, keys from EpochCrypto, and a
## plain subscriber recording every frame the topic carries, as a store node holds them.
## Alice founds the room with Bob; at epoch 1 Carol is admitted first, so the note is sealed
## under a re-keyed epoch. With 1 head Alice posted one event first; with 8, more concurrent
## events than an `after` may name are in her log (MaxHeads). Alice publishes the note, each
## part through publishAuthored with no pad passed, then publishes it again, so the second
## pair goes out on the held path (§4: a retried Send). Correct iff:
##   * the topic carried exactly four data frames for the note, each exactly 90,153 B;
##   * part 0 names exactly the heads the case set up in its `after`;
##   * Bob opens both parts under the case's epoch and folds exactly one note: complete,
##     Alice's, of that length, its record byte-identical to the one Alice sent.
## Run by hand (no argv), it checks every case with doAssert.

import std/tables
import ./voice_room
import ./oracle_emit
import ../../src/transport/transport
import ../../src/crypto/epoch_crypto
import ../../src/coordination/session

const
  Durations = [500, 1_000, 10_000, 30_000, 59_980, 60_000]
  Heads = [0, 1, MaxHeads]
  WireBytes = 1 + 24 + 16 + 90_112          ## kind byte, nonce, MAC, VoiceFrameBytes
  caseCount = Durations.len * Heads.len * 2

type Wire = ref object
  frames: seq[seq[byte]]

proc tap(net: LocalNetwork): Wire =
  let w = Wire()
  newLocalTransport(net).subscribe(Room, proc (m: IncomingMessage) {.gcsafe.} =
    w.frames.add m.payload)
  w

proc dataFrames(w: Wire): seq[seq[byte]] =
  for f in w.frames: (if f.len > 0 and f[0] == 0x00'u8: result.add f)

proc correct(c: int): bool =
  let ms = Durations[c div (Heads.len * 2)]
  let heads = Heads[(c div 2) mod Heads.len]
  let epoch = c mod 2
  doAssert VoiceFrameBytes == 90_112

  let net = newLocalNetwork()
  let founder = newEpochCrypto(aliceKs, Room, @[bobKs.encIdentity()])
  let bobC = newEpochJoiner(bobKs)
  bobC.ingestGrant(founder.grantFor(0, bobKs.encIdentity()))
  let aliceS = newCoordinationSession(newLocalTransport(net), founder, Room)
  let bobS = newCoordinationSession(newLocalTransport(net), bobC, Room)
  if epoch == 1:
    founder.addMember(carolKs.encIdentity())
    bobC.ingestGrant(founder.grantFor(1, bobKs.encIdentity()))
  if heads == 1: aliceS.publish(Event(key: "msg/before", value: "1"))
  if heads == MaxHeads:
    for k in 0 ..< MaxHeads + 4: aliceS.log.ingest(Event(key: "msg/concurrent/" & $k, value: $k))
  if aliceS.heads().len != heads: return false

  let w = tap(net)
  let n = note(aliceKs, ms, 1_792_000_000 + int64(c), byte(c))
  for e in n.parts: aliceS.publishAuthored(aliceKs, e)
  for e in n.parts: aliceS.publishAuthored(aliceKs, e)    # the held path
  let sent = w.dataFrames()
  if sent.len != 4: return false
  for f in sent:
    if f.len != WireBytes: return false

  let first = aliceS.log.find(eventId(n.parts[0]))
  if not first.found or first.event.after.len != heads: return false
  for e in n.parts:
    let id = eventId(e)
    if not bobS.log.find(id).found or bobS.sealedIn.getOrDefault(id, -1) != epoch: return false
  let notes = reduceVoice(bobS.roomEvents())
  if notes.len != 1: return false
  let got = notes[0]
  if got.nid != n.nid or got.author != alice or got.state != vsComplete: return false
  if got.durMs != ms: return false
  let (ok, record) = voiceRecordOf(bobS.roomEvents(), n.nid)
  ok and record == n.record

proc state(c: int): JsonNode = %*{"case": c, "decision_correct": correct(c)}

let arg = oracleStateArg()
if arg == nil:
  for c in 0 ..< caseCount:
    doAssert correct(c), "case " & $c & ": " & $Durations[c div (Heads.len * 2)] & " ms, " &
                         $Heads[(c div 2) mod Heads.len] & " heads, epoch " & $(c mod 2)
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod caseCount)])
