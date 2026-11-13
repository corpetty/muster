## The room as tracker (exo-4d0.4, docs/design/room-swarm.md §5.3). A shared file and the
## members who seed it are log events, folded by `reduceSwarm` over the room's authentic
## view. The fold is order-free and idempotent (invariant 4); a member is a seeder only by
## their own signed announce, and a file is shared only in its sharer's name (invariant 9,
## exo-f76); a member admitted later holds no key to a file shared before them unless a
## member shares it again (invariant 7). Two in-process members over LocalTransport.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/[json, strutils, algorithm, random]
import ../src/log/log
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/blob_seal
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/swarm
import ../src/coordination/flow
import ../src/coordination/room_graph
import ../src/coordination/intents
import ../src/drivers/driver
import ../src/intents/disclosure

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs = newInMemoryKeystore(seed(0x31), seed(0x41))
let bobKs   = newInMemoryKeystore(seed(0x32), seed(0x42))
let carolKs = newInMemoryKeystore(seed(0x33), seed(0x43))
let malKs   = newInMemoryKeystore(seed(0x34), seed(0x44))
let alice = hex(aliceKs.encIdentity().toBytes())
let bob   = hex(bobKs.encIdentity().toBytes())
let carol = hex(carolKs.encIdentity().toBytes())

const topic = "/muster/1/room-swarm/proto"
let net = newLocalNetwork()
let aliceCrypto = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity()])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobKs.encIdentity()))
let aliceS = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bobS = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)

# A file as the sealer would describe it; the fold never opens blobs.
var sealed = SealedBlob(scheme: SealScheme, size: 1234)
for i in 0 ..< 32: (sealed.key[i] = byte(i); sealed.digest[i] = byte(255 - i))
const cid = "zDvZRwzmExampleCiphertextCid"
const net0 = "logos.dev"

proc only(files: seq[SwarmFile]): SwarmFile =
  doAssert files.len == 1, "one file, not " & $files.len
  files[0]

proc seederIds(f: SwarmFile): seq[string] =
  for s in f.seeders: result.add s.member
  result.sort()

# 1. Alice shares a file and seeds it; Bob seeds it too. Both members fold the same index.
let (fid, share) = shareEvent(alice, "minutes.pdf", "application/pdf", cid, net0, sealed, at = 100)
doAssert fid == fileIdOf(alice, cid)
aliceS.publishAuthored(aliceKs, share)
aliceS.publishAuthored(aliceKs, seedEvent(fid, alice, true, "16Uiu2Alice", @["/ip4/1.2.3.4/tcp/8500"], net0, at = 101))
bobS.publishAuthored(bobKs, seedEvent(fid, bob, true, "16Uiu2Bob", @["/ip4/5.6.7.8/tcp/8500"], net0, at = 200))
for (who, s) in {"alice": aliceS, "bob": bobS}:
  let f = only(reduceSwarm(s.roomEvents()))
  doAssert f.fid == fid and f.sharer == alice, who
  doAssert f.name == "minutes.pdf" and f.mime == "application/pdf" and f.size == 1234, who
  doAssert f.cid == cid and f.network == net0 and f.scheme == SealScheme, who
  doAssert f.key == hex(sealed.key) and f.digest == hex(sealed.digest), who & ": the key travels in the room"
  doAssert not f.retracted, who
  doAssert f.seederIds == sorted(@[alice, bob]), who & ": " & $f.seederIds
  for sd in f.seeders:
    if sd.member == bob:
      doAssert sd.peerId == "16Uiu2Bob" and sd.addrs == @["/ip4/5.6.7.8/tcp/8500"] and sd.network == net0
doAssert aliceS.digest() == bobS.digest()
echo "1. a share and two seeds fold the same on both members OK"

# 2. Order-free and idempotent (invariant 4): any order, any duplicates, the same index.
let base = reduceSwarm(aliceS.roomEvents())
block:
  var r = initRand(7)
  let evs = aliceS.roomEvents()
  for _ in 0 ..< 25:
    var shuffled = evs & evs[0 .. r.rand(evs.len - 1)]
    r.shuffle(shuffled)
    doAssert reduceSwarm(shuffled) == base
echo "2. order-free and idempotent OK"

# 3. Only the named member's own signature counts (invariant 9). A seed in Bob's name signed
#    by Mallory, a share in Alice's name signed by Mallory, and an unsigned seed all drop
#    out of the authentic view; a share under a file id that is not its own is ignored.
block:
  let forgedSeed = seedEvent(fid, carol, true, "16Uiu2Fake", @["/ip4/6.6.6.6/tcp/1"], net0, at = 300)
  var j = parseJson(forgedSeed.value)
  j[AuthorSigField] = %hex(malKs.edSign(authorDigest(topic, forgedSeed)))
  let forged = Event(key: forgedSeed.key, value: $j)
  let (_, fakeShare) = shareEvent(alice, "evil.exe", "application/octet-stream", "zDvZOther", net0, sealed, at = 301)
  var k = parseJson(fakeShare.value)
  k[AuthorSigField] = %hex(malKs.edSign(authorDigest(topic, fakeShare)))
  let forgedShare = Event(key: fakeShare.key, value: $k)
  let unsigned = seedEvent(fid, carol, true, "16Uiu2Bare", @[], net0, at = 302)
  # a validly signed share whose key claims another file's id: squatting, ignored
  let (_, bobShare) = shareEvent(bob, "squat", "text/plain", "zDvZSquat", net0, sealed, at = 303)
  let squat = signAuthored(bobKs, topic, Event(key: "file/" & fid, value: bobShare.value))
  let evs = authenticEvents(aliceS.roomEvents() & @[forged, forgedShare, unsigned, squat], topic)
  doAssert reduceSwarm(evs) == base, "no forgery changes the index"
echo "3. forged seeds and shares, unsigned seeds and squatted ids change nothing OK"

# 4. A seeder's newest announce wins: unseed, then seed again from new addresses. Two
#    announces at the same time resolve the same way on every member.
block:
  bobS.publishAuthored(bobKs, seedEvent(fid, bob, false, "", @[], net0, at = 210))
  doAssert only(reduceSwarm(bobS.roomEvents())).seederIds == @[alice], "Bob stopped seeding"
  bobS.publishAuthored(bobKs, seedEvent(fid, bob, true, "16Uiu2Bob", @["/ip4/9.9.9.9/tcp/8500"], net0, at = 220))
  let f = only(reduceSwarm(aliceS.roomEvents()))
  doAssert f.seederIds == sorted(@[alice, bob])
  for sd in f.seeders:
    if sd.member == bob: doAssert sd.addrs == @["/ip4/9.9.9.9/tcp/8500"], "the newest addresses"
  let a = signAuthored(bobKs, topic, seedEvent(fid, bob, true, "16Uiu2Bob", @["/ip4/1.1.1.1/tcp/1"], net0, at = 500))
  let b = signAuthored(bobKs, topic, seedEvent(fid, bob, false, "", @[], net0, at = 500))
  let evs = aliceS.roomEvents()
  doAssert reduceSwarm(evs & @[a, b]) == reduceSwarm(@[b] & evs & @[a]), "a tie resolves the same in any order"
echo "4. the newest announce wins; ties resolve the same everywhere OK"

# 5. Only the sharer retracts. A retract hides the file from the panel; it unshares nothing.
block:
  let byBob = signAuthored(bobKs, topic, retractEvent(fid, bob, at = 400))
  doAssert not only(reduceSwarm(aliceS.roomEvents() & @[byBob])).retracted, "Bob cannot retract Alice's file"
  aliceS.publishAuthored(aliceKs, retractEvent(fid, alice, at = 401))
  let f = only(reduceSwarm(bobS.roomEvents()))
  doAssert f.retracted and f.key == hex(sealed.key), "retracted, and still what members already hold"
echo "5. only the sharer retracts OK"

# 6. Invariant 7: Carol, admitted at epoch 1, holds no key to a file shared in epoch 0. Bob
#    shares it again in epoch 1 — the same blob and key, in his own name — and now she does.
block:
  aliceCrypto.addMember(carolKs.encIdentity())
  bobCrypto.ingestGrant(aliceCrypto.grantFor(1, bobKs.encIdentity()))
  let carolCrypto = newEpochJoiner(carolKs)
  carolCrypto.ingestGrant(aliceCrypto.grantFor(1, carolKs.encIdentity()))
  let carolS = newCoordinationSession(newLocalTransport(net), carolCrypto, topic)
  carolS.catchUp()
  doAssert reduceSwarm(carolS.roomEvents()).len == 0, "nothing from before Carol's epoch"
  let f = only(reduceSwarm(bobS.roomEvents()))
  let (fid2, again) = reshareEvent(bob, f, at = 600)
  bobS.publishAuthored(bobKs, again)
  bobS.publishAuthored(bobKs, seedEvent(fid2, bob, true, "16Uiu2Bob", @["/ip4/9.9.9.9/tcp/8500"], net0, at = 601))
  let seen = only(reduceSwarm(carolS.roomEvents()))
  doAssert seen.sharer == bob and seen.fid == fid2 and fid2 != fid
  doAssert seen.cid == cid and seen.key == hex(sealed.key) and seen.digest == hex(sealed.digest)
  doAssert seen.seederIds == @[bob], "Carol learns only the seeders announced in her epoch"
echo "6. a later joiner holds no earlier key until a member shares it again OK"

# 7. A name is the sharer's word: it is shown, and saved, without any path in it.
block:
  for (raw, want) in [("../../etc/passwd", "passwd"), ("C:\\Users\\x\\a.txt", "a.txt"),
                      ("", "file"), ("..", "file"), ("bad\0name\n.txt", "bad_name_.txt")]:
    doAssert safeFileName(raw) == want, raw.escape & " -> " & safeFileName(raw)
  let (_, e) = shareEvent(alice, "../../.bashrc", "text/plain", "zDvZPath", net0, sealed, at = 700)
  let f = only(reduceSwarm(@[signAuthored(aliceKs, topic, e)]))
  doAssert f.name == ".bashrc"
echo "7. names carry no path OK"

# 8. What the room learns, said where the room says it: the flow names the file and its key
#    to the members at a share and the storage address at a seed; the room map credits each
#    entry to the member who signed it.
block:
  let stub: DriverFor = proc(kind: string): Driver = newStubDriver(rounds = 1, threshold = 1, verifyResult = true)
  let evs = aliceS.roomEvents()
  let rows = reduceFlow(evs, stub, @[alice, bob])
  proc fields(to: Observer): seq[string] =
    for r in rows:
      if r.kind == "file" and r.to == to and r.field notin result: result.add r.field
    result.sort()
  doAssert fields(obRoomMember) == @["file", "file-key", "storage-address"], $fields(obRoomMember)
  doAssert fields(obStoreNode) == @["timing", "topic"], "the store node sees envelopes only"
  doAssert fields(obStorageDht) == @["ciphertext-cid", "provider"], $fields(obStorageDht)
  doAssert fields(obStoragePeer) == @["ciphertext", "node-address"], $fields(obStoragePeer)
  for r in rows:
    if r.to in {obStorageDht, obStoragePeer}:
      doAssert r.field notin ["file", "file-key", "name"], "Storage never sees the file or its key"
  let g = reduceRoomGraph(evs, stub, @[alice, bob], alice)
  var credited = 0
  for n in g.nodes:
    if n.kind == "entry" and n.attrs{"kind"}.getStr() == "file":
      doAssert n.attrs{"basis"}.getStr() == "author-signed", $n.attrs
      # uncounted by the map, yet its signer's: its facet says both, never "names no one"
      let last = n.attrs["facets"][^1]
      doAssert not n.attrs["counted"].getBool() and last["about"].getStr() == "this entry" and
               last["mechanism"].getStr() == "the fold counts it for nothing; its author signed it, bound to this room",
               $last
      inc credited
  doAssert credited >= 4, "every file entry is credited to its signer (" & $credited & ")"
  var toDht, toPeers = 0
  for e in g.edges:
    if e.kind == "leaves" and e.src.startsWith("e:"):
      if e.dst == "o:storage-dht": inc toDht
      if e.dst == "o:storage-peer": inc toPeers
      doAssert "never the file or its key" in e.attrs{"mechanism"}.getStr(), $e.attrs
  doAssert toDht >= 1 and toPeers >= 1, "the map shows what reached the storage network"
echo "8. flow rows and room-map attribution for file entries OK"

echo "swarm_test: all OK"
