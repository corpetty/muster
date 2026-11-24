## The room as tracker (exo-4d0.4, docs/design/room-swarm.md §5.3): which files the room
## shares, and which members seed each one, as log events folded by `reduceSwarm`.
##
##   file/<fid>                 a share: name, mime, size, the plaintext digest, the
##                              ciphertext CID, the file key, the seal scheme, the storage
##                              network — in the sharer's name ("author")
##   file/<fid>/seed/<who>      a member's announce: seeding or not ("on"), how to reach
##                              their storage node (peer id, addresses, network)
##   file/<fid>/retract         the sharer hides the file from the room's list
##
## Every `file/` event names its author and carries their signature (authorship.nim), so
## the room's view drops one in anyone else's name: a member is a seeder only because they
## said so (invariant 9), and the client never infers a holder from what a storage node
## sees. The fold is a pure, order-free function of the events (invariant 4): a seeder's
## newest announce wins by (at, event id), the same on every member.
##
## The file id is content-addressed over (sharer, CID), so every member agrees on it and no
## member can post under another's file id. Sharing the same blob again — into a later
## epoch, for members admitted since (invariant 7) — is a new share in the re-sharer's own
## name with the same CID and key: the member disclosing what they legitimately hold.
##
## The share carries the key in the clear INSIDE the room: the event is sealed to the
## epoch it was published in, so only that epoch's members open it. Nothing here touches
## Storage; the hosted layer (S4) uploads, fetches and opens blobs.

import std/[json, strutils, tables, algorithm, os]
when defined(posix): import std/posix
import ../log/log
import ../security/text_controls
import ../dcbor/dcbor
import ../hashing/hash_input
import ../crypto/blob_seal

const FileIdDomain* = "muster.swarm.file-id.v1"

type
  SwarmSeeder* = object
    member*: string            ## the seeder's encryption identity (hex)
    peerId*: string            ## their storage node's libp2p peer id
    addrs*: seq[string]        ## multiaddresses they announced
    network*: string           ## the storage network they are on
    at*: int64                 ## their clock at the announce
  SwarmFile* = object
    fid*: string
    sharer*: string
    name*: string              ## safe to show and to save under: no path in it
    mime*: string
    size*: uint64              ## plaintext bytes
    digest*: string            ## plaintextDigest (hex) — the open refuses anything else
    cid*: string               ## the ciphertext's manifest CID in Logos Storage
    key*: string               ## the file key (hex)
    scheme*: string            ## how the blob is sealed (blob_seal.SealScheme)
    network*: string           ## the storage network it was uploaded on
    at*: int64                 ## the sharer's clock at the share
    retracted*: bool
    seeders*: seq[SwarmSeeder] ## by member id

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc isHex(s: string, n: int): bool =
  s.len == n and s.allCharsInSet(HexDigits)

proc fileIdOf*(sharer, cid: string): string =
  ## The file id every member derives for a share: 16 bytes of a domain-separated digest.
  let d = digest(hashInput(FileIdDomain, @[("cid", cbText(cid)),
                                            ("sharer", cbText(sharer.toLowerAscii))]))
  hexOf(d[0 ..< 16])

proc safeFileName*(raw: string): string =
  ## The sharer's name for a file, with no path in it: the part after the last separator,
  ## control characters replaced, and the Unicode format controls that reorder or hide what
  ## a name shows dropped (U+202E would show "invoice<U+202E>fdp.exe" as "invoiceexe.pdf";
  ## exo-3b3.18, audit P4-10). "." and ".." and an empty name read "file".
  var s = raw
  let cut = max(s.rfind('/'), s.rfind('\\'))
  if cut >= 0: s = s[cut + 1 .. ^1]
  for c in s.mitems:
    if ord(c) < 0x20 or ord(c) == 0x7f: c = '_'
  s = stripFormatControls(s)
  if s.len == 0 or s == "." or s == "..": "file" else: s

proc isUnder(path, dir: string): bool =
  ## Is `path` `dir` itself or inside it (both absolute, normalized)?
  if dir.len == 0: return false
  let d = (if dir.endsWith("/") and dir.len > 1: dir[0 ..< ^1] else: dir)
  path == d or path.startsWith(d & "/")

proc realOrSame(path: string): string =
  ## The path with every link resolved, when it exists; else as given, normalized.
  try: expandFilename(path)
  except CatchableError: normalizedPath(path)

proc hiddenUnder(path, home: string): bool =
  ## Does `path`, inside `home`, have a component (folder or file) starting with "."?
  if home.len == 0 or not isUnder(path, home): return false
  let h = (if home.endsWith("/") and home.len > 1: home[0 ..< ^1] else: home)
  if path.len <= h.len: return false
  for part in path[h.len + 1 .. ^1].split('/'):
    if part.len > 0 and part[0] == '.': return true
  false

proc shareRefusal*(path, home: string, ownDirs: seq[string]): string =
  ## Why `path` may not be shared into a room, or "" when it may (exo-3b3.17, audit P4-01). Any
  ## module loaded beside Muster can ask it to share a file, so this holds whoever asks:
  ## the path must be absolute and name a regular file, and, as given and with its links
  ## resolved, must not sit in a hidden folder (or be a hidden file) under the home folder,
  ## in one of Muster's own folders (`ownDirs`: where identity.mks and the wallet live), or
  ## in the kernel's trees (/proc, /sys, /dev).
  if path.len == 0 or not path.isAbsolute: return "a file is named by its full path"
  let given = normalizedPath(path)
  let real = realOrSame(path)
  let homes = (if home.len > 0: @[normalizedPath(home), realOrSame(home)] else: @[])
  for p in [given, real]:
    for k in ["/proc", "/sys", "/dev"]:
      if isUnder(p, k): return "a file in " & k & " is the system's, never shared"
    for d in ownDirs:
      if d.len == 0: continue
      if isUnder(p, normalizedPath(d)) or isUnder(p, realOrSame(d)):
        return "a file in Muster's own folder is never shared (it holds this member's keys)"
    for h in homes:
      if hiddenUnder(p, h):
        return "a hidden file, or a file in a hidden folder, is never shared"
  when defined(posix):
    var st: Stat
    if stat(real.cstring, st) != 0: return "no such file"
    if not S_ISREG(st.st_mode): return "only a regular file is shared"
  else:
    if not fileExists(real): return "no such file"
  ""

proc shareBody(sharer, name, mime, cid, network, scheme: string, size: uint64,
               digest, key: string, at: int64): JsonNode =
  %*{"author": sharer, "name": name, "mime": mime, "size": int64(size), "digest": digest,
     "cid": cid, "key": key, "scheme": scheme, "network": network, "at": at}

proc shareEvent*(sharer, name, mime, cid, network: string, sealed: SealedBlob,
                 at: int64): (string, Event) =
  ## A share in `sharer`'s name (they sign it: authorship.publishAuthored), and its file id.
  let fid = fileIdOf(sharer, cid)
  (fid, Event(key: "file/" & fid,
              value: $shareBody(sharer, name, mime, cid, network, sealed.scheme, sealed.size,
                                hexOf(sealed.digest), hexOf(sealed.key), at)))

proc reshareEvent*(sharer: string, f: SwarmFile, at: int64): (string, Event) =
  ## The same blob shared again in `sharer`'s name — for members admitted since it was
  ## first shared (invariant 7). Same CID, key and digest; a new file id.
  let fid = fileIdOf(sharer, f.cid)
  (fid, Event(key: "file/" & fid,
              value: $shareBody(sharer, f.name, f.mime, f.cid, f.network, f.scheme, f.size,
                                f.digest, f.key, at)))

proc seedEvent*(fid, who: string, on: bool, peerId: string, addrs: seq[string],
                network: string, at: int64): Event =
  ## `who` announces they seed `fid` (on) or have stopped (off). Signed by `who`.
  Event(key: "file/" & fid & "/seed/" & who,
        value: $(%*{"on": on, "peerId": peerId, "addrs": addrs, "network": network, "at": at}))

proc retractEvent*(fid, who: string, at: int64): Event =
  ## The sharer hides `fid` from the room's list. Counted only when `who` is the sharer.
  Event(key: "file/" & fid & "/retract", value: $(%*{"author": who, "at": at}))

proc str(j: JsonNode, k: string): (bool, string) =
  let v = j{k}
  if v != nil and v.kind == JString: (true, v.getStr()) else: (false, "")

proc int64Of(j: JsonNode, k: string): (bool, int64) =
  let v = j{k}
  if v != nil and v.kind == JInt: (true, v.getBiggestInt()) else: (false, 0'i64)

proc parseShare(fid: string, e: Event): (bool, SwarmFile) =
  try:
    let j = parseJson(e.value)
    if j.kind != JObject: return
    let (a1, sharer) = j.str("author")
    let (a2, name) = j.str("name")
    let (a3, mime) = j.str("mime")
    let (a4, digest) = j.str("digest")
    let (a5, cid) = j.str("cid")
    let (a6, key) = j.str("key")
    let (a7, scheme) = j.str("scheme")
    let (a8, network) = j.str("network")
    let (a9, size) = j.int64Of("size")
    let (a10, at) = j.int64Of("at")
    if not (a1 and a2 and a3 and a4 and a5 and a6 and a7 and a8 and a9 and a10): return
    if size < 0 or cid.len == 0 or scheme.len == 0: return
    if not (isHex(digest, 64) and isHex(key, 64)): return
    if fileIdOf(sharer, cid) != fid: return              # a squatted file id
    (true, SwarmFile(fid: fid, sharer: sharer.toLowerAscii, name: safeFileName(name),
                     mime: mime, size: uint64(size), digest: digest.toLowerAscii, cid: cid,
                     key: key.toLowerAscii, scheme: scheme, network: network, at: at))
  except CatchableError:
    (false, SwarmFile())

proc parseSeed(who: string, e: Event): (bool, bool, SwarmSeeder) =
  ## (well-formed, on, seeder)
  try:
    let j = parseJson(e.value)
    if j.kind != JObject: return
    let on = j{"on"}
    let (a1, at) = j.int64Of("at")
    if on == nil or on.kind != JBool or not a1: return
    var sd = SwarmSeeder(member: who.toLowerAscii, at: at)
    sd.peerId = j.str("peerId")[1]
    sd.network = j.str("network")[1]
    let addrs = j{"addrs"}
    if addrs != nil and addrs.kind == JArray:
      for a in addrs:
        if a.kind == JString: sd.addrs.add a.getStr()
    if on.getBool() and sd.peerId.len == 0: return       # seeding names its node
    (true, on.getBool(), sd)
  except CatchableError:
    (false, false, SwarmSeeder())

proc newer(at: int64, id: string, thanAt: int64, thanId: string): bool =
  at > thanAt or (at == thanAt and id > thanId)

proc reduceSwarm*(events: seq[Event]): seq[SwarmFile] =
  ## The room's files and their seeders. Pass the room's authentic view
  ## (`roomEvents(s)`): the fold trusts that every `file/` event's author signed it.
  var shares = initTable[string, (string, SwarmFile)]()             # fid -> (event id, file)
  var seeds = initTable[(string, string), (int64, string, bool, SwarmSeeder)]()
  var retracts = initTable[string, seq[string]]()                    # fid -> retracting authors
  for e in events:
    let p = e.key.split('/')
    if p[0] != "file" or p.len < 2 or p[1].len == 0: continue
    let fid = p[1]
    let id = eventId(e)
    if p.len == 2:
      let (ok, f) = parseShare(fid, e)
      if ok and (fid notin shares or id < shares[fid][0]): shares[fid] = (id, f)
    elif p.len == 4 and p[2] == "seed" and p[3].len > 0:
      let (ok, on, sd) = parseSeed(p[3], e)
      if not ok: continue
      let k = (fid, sd.member)
      if k notin seeds or newer(sd.at, id, seeds[k][0], seeds[k][1]):
        seeds[k] = (sd.at, id, on, sd)
    elif p.len == 3 and p[2] == "retract":
      try:
        let j = parseJson(e.value)
        if j.kind == JObject:
          let (ok, who) = j.str("author")
          if ok: retracts.mgetOrPut(fid, @[]).add who.toLowerAscii
      except CatchableError: discard
  for fid, (_, f0) in shares:
    var f = f0
    f.retracted = f.sharer in retracts.getOrDefault(fid)
    for k, v in seeds:
      if k[0] == fid and v[2]: f.seeders.add v[3]
    f.seeders.sort(proc(a, b: SwarmSeeder): int = cmp(a.member, b.member))
    result.add f
  result.sort(proc(a, b: SwarmFile): int =
    if a.at != b.at: cmp(a.at, b.at) else: cmp(a.fid, b.fid))
