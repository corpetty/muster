## The room swarm end to end in process (exo-4d0.5, docs/design/room-swarm.md §5.4): share,
## fetch, seed and private fetch, over two members' sessions on LocalTransport and their
## storage nodes on one LocalStorageNet. Nothing is mocked: the blobs are really sealed,
## stored, served and opened. Needs libsecp256k1 + libsodium (see tests/README.md).

import std/[os, strutils, sequtils, algorithm]
import ../src/log/log
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/sodium
import ../src/crypto/blob_seal
import ../src/storage/blob_store
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/swarm
import ../src/coordination/swarm_live

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# A node whose downloads never move while `stuck`: what no seeder online looks like (§9).
type StuckStore = ref object of BlobStore
  inner: BlobStore
  stuck: bool
method reach(b: StuckStore): PeerReach = b.inner.reach()
method upload(b: StuckStore, path: string): string = b.inner.upload(path)
method download(b: StuckStore, cid, dest: string, private, serve: bool): string =
  if b.stuck: "stuck" else: b.inner.download(cid, dest, private, serve)
method job(b: StuckStore, id: string): BlobJob =
  if id == "stuck": BlobJob(id: id, state: jsRunning) else: b.inner.job(id)
method poll(b: StuckStore) = b.inner.poll()
method has(b: StuckStore, cid: string): bool = b.inner.has(cid)
method serving(b: StuckStore, cid: string): bool = b.inner.serving(cid)
method setServing(b: StuckStore, cid: string, on: bool) = b.inner.setServing(cid, on)
method connect(b: StuckStore, peer: PeerReach) = b.inner.connect(peer)
method remove(b: StuckStore, cid: string) = b.inner.remove(cid)

let root = getTempDir() / ("muster-swarm-live-" & $getCurrentProcessId())
createDir(root)

const topic = "/muster/1/room-swarm-live/proto"
let ks = @[newInMemoryKeystore(seed(0x51), seed(0x61)), newInMemoryKeystore(seed(0x52), seed(0x62)),
           newInMemoryKeystore(seed(0x53), seed(0x63))]
let net = newLocalNetwork()
let founder = newEpochCrypto(ks[0], topic, @[ks[1].encIdentity(), ks[2].encIdentity()])
var sessions = @[newCoordinationSession(newLocalTransport(net), founder, topic)]
for i in 1 .. 2:
  let j = newEpochJoiner(ks[i])
  j.ingestGrant(founder.grantFor(0, ks[i].encIdentity()))
  sessions.add newCoordinationSession(newLocalTransport(net), j, topic)
let ids = ks.mapIt(hex(it.encIdentity().toBytes()))

let storageNet = newLocalStorageNet("logos.dev")
var clock = 1000'i64
var nodes: seq[SwarmNode]
for i in 0 .. 2:
  createDir(root / $i)
  nodes.add newSwarmNode(newLocalBlobStore(storageNet, root / $i / "repo"), ks[i],
                         root / $i / "work", proc(): int64 = (inc clock; clock))
let (alice, bob, carol) = (0, 1, 2)

proc pumpAll() =
  for _ in 0 .. 3:
    for i in 0 .. 2: nodes[i].pump(sessions[i])

proc op(i: int, id: string): SwarmOp =
  for o in nodes[i].ops():
    if o.id == id: return o
  doAssert false, "no op " & id

proc files(i: int): seq[SwarmFile] = reduceSwarm(sessions[i].roomEvents())
proc seeders(f: SwarmFile): seq[string] = f.seeders.mapIt(it.member)

let src = root / "Q3 minutes.pdf"
let plain = randomBytes(150_000)
block:
  var s = newString(plain.len)
  for i, x in plain: s[i] = char(x)
  writeFile(src, s)

# 1. Alice shares: sealed, uploaded, then the share and her seed reach the room. The upload
#    went out under a neutral name; the room has the real one.
let shareOp = nodes[alice].share(sessions[alice], src, "application/pdf")
pumpAll()
doAssert op(alice, shareOp).state == opDone, op(alice, shareOp).error
let fid = op(alice, shareOp).fid
block:
  for i in 0 .. 2:
    let fs = files(i)
    doAssert fs.len == 1 and fs[0].fid == fid and fs[0].name == "Q3 minutes.pdf" and fs[0].size == 150_000
    doAssert seeders(fs[0]) == @[ids[alice]]
  let f = files(bob)[0]
  let store = LocalBlobStore(nodes[alice].store)
  doAssert store.manifestName(f.cid).endsWith(".bin") and "minutes" notin store.manifestName(f.cid),
    "Storage's manifest names nothing: " & store.manifestName(f.cid)
  doAssert toSeq(walkDir(root / "0" / "work")).len == 0, "no sealed temp left behind"
echo "1. share: sealed, uploaded under a neutral name, announced in the room OK"

# 2. Bob fetches into his folder: he dials the seeders the room names, opens and checks the
#    blob, and — seeding by default — announces himself.
let dest = root / "1" / "Downloads"
createDir(dest)
let fetchOp = nodes[bob].fetch(sessions[bob], fid, dest, private = false)
pumpAll()
doAssert op(bob, fetchOp).state == opDone, op(bob, fetchOp).error
let got = op(bob, fetchOp).dest
doAssert got == dest / "Q3 minutes.pdf"
doAssert readFile(got).len == 150_000 and readFile(got)[0] == char(plain[0])
doAssert seeders(files(carol)[0]) == @[ids[alice], ids[bob]].sorted()
echo "2. fetch: opened, verified, saved, and seeded by default OK"

# 3. A second fetch never overwrites: the file lands beside the first.
block:
  let again = nodes[bob].fetch(sessions[bob], fid, dest, private = false)
  pumpAll()
  doAssert op(bob, again).dest == dest / "Q3 minutes (1).pdf", op(bob, again).dest
echo "3. a second fetch lands beside the first OK"

# 4. Alice's node goes away; Carol still gets the file, from Bob.
block:
  nodes[alice].store.remove(files(carol)[0].cid)
  let o = nodes[carol].fetch(sessions[carol], fid, root / "2", private = true)
  pumpAll()
  doAssert op(carol, o).state == opDone, op(carol, o).error
  # 5. ...and her fetch was private: she dialled no seeder (that would hand them her
  #    address), announced nothing, serves nothing onward, and Bob's node saw a mix path ask.
  doAssert LocalBlobStore(nodes[carol].store).connected().len == 0, "a private fetch dials nobody"
  doAssert ids[carol] notin seeders(files(alice)[0]), "a private fetch announces nothing"
  doAssert not nodes[carol].store.serving(files(alice)[0].cid)
  doAssert LocalBlobStore(nodes[bob].store).servedLog().anyIt(it.to == MixRequester)
  doAssert not LocalBlobStore(nodes[bob].store).servedLog().anyIt(it.to == nodes[carol].store.reach().peerId)
echo "4. the sharer gone, a seeder serves OK"
echo "5. a private fetch: dials nobody, announces nothing, the server sees a mix path OK"

# 6. Stop seeding, then seed again: the room follows, and the node's serving follows.
block:
  let cid = files(alice)[0].cid
  doAssert nodes[bob].setSeeding(sessions[bob], fid, false) == ""
  doAssert not nodes[bob].store.serving(cid) and ids[bob] notin seeders(files(alice)[0])
  doAssert nodes[bob].setSeeding(sessions[bob], fid, true) == ""
  doAssert nodes[bob].store.serving(cid) and ids[bob] in seeders(files(alice)[0])
  # Alice's node no longer holds the blob: she cannot seed what she does not have
  doAssert "not held" in nodes[alice].setSeeding(sessions[alice], fid, true)
  # Carol fetched privately and still holds it: seeding later is her choice to make
  doAssert nodes[carol].setSeeding(sessions[carol], fid, true) == ""
  doAssert ids[carol] in seeders(files(bob)[0])
echo "6. stop and resume seeding; only what a node holds OK"

# 7. A sharer whose committed digest is not the blob's: the fetch refuses, writes nothing,
#    and neither keeps nor serves the blob.
block:
  let lie = root / "lie.txt"
  writeFile(lie, "the real bytes")
  let sealed = sealFile(lie, root / "lie.sealed")
  let jobId = nodes[alice].store.upload(root / "lie.sealed")
  nodes[alice].store.poll()
  let cid = nodes[alice].store.job(jobId).cid
  var forged = sealed
  forged.digest[0] = forged.digest[0] xor 1
  let (badFid, e) = shareEvent(ids[alice], "lie.txt", "text/plain", cid, "logos.dev", forged, at = 5000)
  sessions[alice].publishAuthored(ks[alice], e)
  sessions[alice].publishAuthored(ks[alice], seedEvent(badFid, ids[alice], true,
    nodes[alice].store.reach().peerId, nodes[alice].store.reach().addrs, "logos.dev", at = 5001))
  let outDir = root / "1" / "lies"
  createDir(outDir)
  let o = nodes[bob].fetch(sessions[bob], badFid, outDir, private = false)
  pumpAll()
  doAssert op(bob, o).state == opFailed and "digest" in op(bob, o).error, op(bob, o).error
  doAssert toSeq(walkDir(outDir)).len == 0, "nothing written"
  doAssert not nodes[bob].store.has(cid), "a refused blob is not kept"
  doAssert ids[bob] notin seeders(reduceSwarm(sessions[bob].roomEvents()).filterIt(it.fid == badFid)[0])
echo "7. a blob that is not what its sharer committed is refused and dropped OK"

# 9. A fetch where nothing arrives fails after FetchStallS, so it can be tried again — and
# the second try, once a seeder answers, saves the file. Never "Fetching…" for good.
block:
  let stuck = StuckStore(inner: nodes[carol].store, stuck: true)
  nodes[carol].store = stuck
  let outDir = root / "stall"
  createDir(outDir)
  let o = nodes[carol].fetch(sessions[carol], fid, outDir, private = false)
  nodes[carol].pump(sessions[carol])
  doAssert op(carol, o).state == opRunning, "still waiting before the stall time"
  clock += FetchStallS
  nodes[carol].pump(sessions[carol])
  doAssert op(carol, o).state == opFailed and "Try again" in op(carol, o).error, op(carol, o).error
  stuck.stuck = false
  let again = nodes[carol].fetch(sessions[carol], fid, outDir, private = false)
  pumpAll()
  doAssert op(carol, again).state == opDone, op(carol, again).error
  doAssert toSeq(walkDir(outDir)).len == 1, "the second try saved it, once"
  nodes[carol].store = stuck.inner
echo "9. a fetch where nothing arrives fails, and trying again saves it OK"

# 8. Refusals before any network: an unknown file, a retracted one.
block:
  let unknown = nodes[bob].fetch(sessions[bob], "00".repeat(16), dest, false)
  doAssert op(bob, unknown).state == opFailed and "no such file" in op(bob, unknown).error
  sessions[alice].publishAuthored(ks[alice], retractEvent(fid, ids[alice], at = 6000))
  let o = nodes[carol].fetch(sessions[carol], fid, root / "2", private = false)
  doAssert op(carol, o).state == opFailed and "retracted" in op(carol, o).error
echo "8. unknown and retracted files are refused up front OK"

removeDir(root)
echo "swarm_live_test: all OK"
