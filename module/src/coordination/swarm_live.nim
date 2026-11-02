## The room swarm's live half (exo-4d0.5, docs/design/room-swarm.md §5.4): share, fetch and
## seed, driven by a pump, over one member's session and their storage node (BlobStore).
##
##   share  seal the file into the work dir under a neutral name → upload → once the node
##          has it: publish the share, and this member's seed; drop the sealed temp.
##   fetch  refuse an unknown or retracted file, or an unknown seal scheme, up front →
##          dial every seeder the room names on this node's network (not for a private
##          fetch: dialling a seeder hands them this node's address) → download the blob
##          into the work dir → open it, which refuses unless it is exactly what the sharer
##          committed → save it beside, never over, what is in the destination folder →
##          seed it unless the fetch was private. A refused blob is removed, never served.
##   seed   serve (or stop serving) a blob this node holds, and say so in the room.
##
## Every step that waits on the network is a BlobStore job, read in `pump` (the intents
## tick, on the platform), so nothing here blocks the module thread. The seed events carry
## this node's peer id and addresses: the room is the tracker (§9, decided 2026-10-15).

import std/[os, strutils, tables, sequtils]
import ../crypto/keystore
import ../crypto/blob_seal
import ../crypto/curve25519
import ../storage/blob_store
import ./session
import ./authorship
import ./swarm

type
  SwarmOpKind* = enum opShare = "share", opFetch = "fetch"
  SwarmOpState* = enum opRunning = "running", opDone = "done", opFailed = "failed"
  SwarmOp* = object
    id*: string
    kind*: SwarmOpKind
    state*: SwarmOpState
    error*: string
    fid*: string            ## the file (known at once for a fetch, once shared for a share)
    name*: string
    job*: string            ## the BlobStore job in flight
    bytes*, total*: uint64  ## progress of that job
    dest*: string           ## a fetch: the folder asked for, then the file saved
    private*: bool
    # share
    src, mime, sealedPath: string
    sealed: SealedBlob
    # fetch
    blobPath: string
    file: SwarmFile
    movedAt: int64          ## when its bytes last moved (or it started): a fetch that stalls fails

  SwarmNode* = ref object
    store*: BlobStore
    ks: Keystore
    me: string
    work: string
    now: proc(): int64
    ops: OrderedTable[string, SwarmOp]
    next: int

const FetchStallS* = 120'i64
  ## How long a fetch may go with no byte arriving before it fails, so it can be tried again:
  ## no seeder online, or none reachable, never answers, and a fetch has no other end.

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc newSwarmNode*(store: BlobStore, ks: Keystore, work: string,
                   now: proc(): int64): SwarmNode =
  createDir(work)
  SwarmNode(store: store, ks: ks, me: hexOf(ks.encIdentity().toBytes()), work: work, now: now)

proc ops*(n: SwarmNode): seq[SwarmOp] =
  for _, o in n.ops: result.add o

proc add(n: SwarmNode, o: SwarmOp): string =
  inc n.next
  result = $o.kind & "-" & $n.next
  var k = o
  k.id = result
  n.ops[result] = k

proc fail(o: var SwarmOp, why: string) =
  o.state = opFailed
  o.error = why

proc taken(path: string): bool =
  ## Anything already at `path`: a file, a folder, or a symlink — dangling ones included,
  ## which fileExists and dirExists miss because they follow the link (derived-exo-4d0.4 s5).
  symlinkExists(path) or fileExists(path) or dirExists(path)

proc freeName*(dir, name: string): string =
  ## `dir/name`, or `dir/name (1).ext`, `(2)`… — the first that is not taken.
  result = dir / name
  if not taken(result): return
  let (_, stem, ext) = splitFile(name)
  for i in 1 .. 10_000:
    result = dir / (stem & " (" & $i & ")" & ext)
    if not taken(result): return
  raise newException(IOError, "no free name for " & name & " in " & dir)

proc fileOf(s: CoordinationSession, fid: string): (bool, SwarmFile) =
  for f in reduceSwarm(s.roomEvents()):
    if f.fid == fid: return (true, f)

proc announce(n: SwarmNode, s: CoordinationSession, fid: string, on: bool) =
  let r = n.store.reach()
  s.publishAuthored(n.ks, seedEvent(fid, n.me, on, (if on: r.peerId else: ""),
                                    (if on: r.addrs else: @[]), r.network, n.now()))

proc share*(n: SwarmNode, s: CoordinationSession, path, mime: string): string =
  ## Start sharing the file at `path` into the room. Returns the op id; `pump` finishes it.
  var o = SwarmOp(kind: opShare, src: path, mime: mime, name: safeFileName(extractFilename(path)))
  try:
    o.sealedPath = n.work / neutralName()
    o.sealed = sealFile(path, o.sealedPath)
    o.total = o.sealed.size
    o.job = n.store.upload(o.sealedPath)
    o.state = opRunning
  except CatchableError as e:
    if o.sealedPath.len > 0 and fileExists(o.sealedPath): removeFile(o.sealedPath)
    o.fail(e.msg)
  n.add(o)

proc fetch*(n: SwarmNode, s: CoordinationSession, fid, destDir: string, private: bool): string =
  ## Start fetching file `fid` into `destDir`. A private fetch dials no seeder and announces
  ## nothing; it finds the blob through the storage network over its private path.
  var o = SwarmOp(kind: opFetch, fid: fid, dest: destDir, private: private)
  let (found, f) = s.fileOf(fid)
  if not found: (o.fail("no such file in this room: " & fid); return n.add(o))
  o.file = f
  o.name = f.name
  o.total = f.size
  if f.retracted: (o.fail("the sharer retracted this file"); return n.add(o))
  if f.scheme != SealScheme: (o.fail("unknown seal scheme: " & f.scheme); return n.add(o))
  if not dirExists(destDir): (o.fail("no such folder: " & destDir); return n.add(o))
  let net = n.store.reach().network
  if not private:
    for sd in f.seeders:
      if sd.member != n.me and sd.network == net:
        n.store.connect(PeerReach(peerId: sd.peerId, addrs: sd.addrs, network: sd.network))
  o.blobPath = n.work / neutralName()
  o.job = n.store.download(f.cid, o.blobPath, private = private, serve = not private)
  o.state = opRunning
  o.movedAt = n.now()
  n.add(o)

proc setSeeding*(n: SwarmNode, s: CoordinationSession, fid: string, on: bool): string =
  ## Serve (or stop serving) `fid`, and say so in the room. "" on success, else why not.
  let (found, f) = s.fileOf(fid)
  if not found: return "no such file in this room: " & fid
  if on and not n.store.has(f.cid): return "not held by this node: fetch it first"
  if n.store.has(f.cid): n.store.setServing(f.cid, on)
  n.announce(s, fid, on)
  ""

proc finishShare(n: SwarmNode, s: CoordinationSession, o: var SwarmOp, j: BlobJob) =
  try:
    let r = n.store.reach()
    let (fid, e) = shareEvent(n.me, o.name, o.mime, j.cid, r.network, o.sealed, n.now())
    s.publishAuthored(n.ks, e)
    n.announce(s, fid, true)
    o.fid = fid
    o.state = opDone
  except CatchableError as e:
    o.fail(e.msg)

proc finishFetch(n: SwarmNode, s: CoordinationSession, o: var SwarmOp) =
  let f = o.file
  try:
    var key: array[32, byte]
    var digest: Sha256Digest
    for i in 0 ..< 32:
      key[i] = byte(parseHexInt(f.key[2*i .. 2*i+1]))
      digest[i] = byte(parseHexInt(f.digest[2*i .. 2*i+1]))
    let target = freeName(o.dest, f.name)
    openFile(o.blobPath, target, key, f.size, digest)
    o.dest = target
    o.state = opDone
    if not o.private: n.announce(s, f.fid, true)
  except CatchableError as e:
    # refused: the blob is not what its sharer committed (or cannot be saved) — never keep
    # or serve it
    n.store.remove(f.cid)
    o.fail("refused: " & e.msg)

proc pump*(n: SwarmNode, s: CoordinationSession) =
  ## Advance every running op from what the node reported. Call on each tick.
  n.store.poll()
  for id in toSeq(n.ops.keys):
    var o = n.ops[id]
    if o.state != opRunning: continue
    let j = n.store.job(o.job)
    if j.bytes != o.bytes: o.movedAt = n.now()
    o.bytes = j.bytes
    if j.total > 0: o.total = j.total
    case j.state
    of jsRunning:
      if o.kind == opFetch and n.now() - o.movedAt >= FetchStallS:
        o.fail("nothing arrived for " & $(FetchStallS div 60) & " minutes: no seeder may be online. Try again later")
    of jsFailed:
      o.fail(j.error)
    of jsDone:
      if o.kind == opShare: n.finishShare(s, o, j)
      else: n.finishFetch(s, o)
    if o.state != opRunning:
      for p in [o.sealedPath, o.blobPath]:
        if p.len > 0 and fileExists(p): removeFile(p)
    n.ops[id] = o
