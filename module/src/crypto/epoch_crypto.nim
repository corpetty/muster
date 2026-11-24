## EpochCrypto — the F-16 stopgap behind ConversationCrypto (ADR-010, amended).
##
## Per-conversation membership epochs. Each epoch has a fresh symmetric key that
## seals envelopes (AEAD, libsodium); the key travels to each member in a libsodium
## sealed box (ECIES over X25519) to their encryption identity (F-14: separate from
## the secp256k1 key they sign with). A membership change opens a new epoch, so:
##   • a member added at epoch N receives ONLY epoch N's key → cannot open any
##     envelope sealed at an earlier epoch (F-16 forward secrecy for joiners);
##   • a member removed at epoch N is absent from epoch N+1 and never receives its
##     key → cannot open anything sent after removal (F-16 removal).
##
## Explicitly a stopgap: native logos-chat-module (MLS) provides this once it ships
## persistence + removal; it binds the SAME ConversationCrypto interface and this
## file is deleted. Kept thin for exactly that reason.
##
## Epoch 0 is the one key no grant carries: whoever joins a room by name founds it
## (coordinate_join), and nobody hands it to anyone. So it is DERIVED from the founder's
## keystore and the room (Keystore.foundingKey, exo-7b3), never drawn at random: a
## restart rebuilds it, and the room stays reduce(log + keys) (invariant 4). Epochs 1+
## come back from the grants sealed to the member, as before.
##
## Every grant and every envelope is signed (exo-3b3, the 2026-11-22 audit; FS-2). A
## sealed box is anonymous, so before this anyone who could publish on the topic and knew
## a member's chat id could hand that member a key of their own choosing, at any epoch,
## and read whatever the member sent next. Now:
##
##   • a grant is the admitter's Ed25519 signature over a hash-input record of the room,
##     the epoch, the key of the epoch it follows, the new roster, the new key's id and
##     the admitter. A member takes it only when the admitter is a member of the epoch it
##     follows and it is the next epoch (cur+1, or a short gap when grants arrive out of
##     order or the member was away from an epoch); never one naming a member the room
##     has removed; and with no wrap (the epoch field is 4 bytes, so it stops at 2^31).
##     Someone who holds no epoch of the room takes a first grant only while it asked to
##     join (requestJoin) or expects one from the member who invited it.
##   • an envelope carries its sender's identity and signature over (room, epoch, the
##     payload's digest), and is opened only when the sender is a member of that epoch.
##     A sender no longer in the current roster — removed since — is accepted only for a
##     short grace after this member learned of the removal (what was in flight), or from
##     the member's own journal (it was accepted when it arrived). So a removed member
##     cannot keep writing under the keys they held, and an envelope cannot be re-sealed
##     under another epoch than the one its sender signed.
##   • two grants for one epoch from the same parent (a concurrent admit and removal):
##     the one whose signed record digests smaller is the epoch on every member that has
##     not moved past it; the other's key is kept for opening what was sealed under it.
##
## Envelope wire: secretbox(epochKey, plaintext) = nonce(24) ++ MAC(16) ++ ciphertext,
## the plaintext v(1)=2 ++ sender(64) ++ sig(64) ++ payload. No epoch number rides in the
## clear (exo-661.7): a reader tries the keys it holds, newest first, and the one whose MAC
## verifies is the envelope's epoch. A store node sees a random nonce and ciphertext, the
## same shape in every epoch.

import std/[algorithm, sets, tables, times]
import ./sodium
import ./curve25519
import ./conversation
import ./keystore
import ../dcbor/dcbor
import ../hashing/hash_input
import ../hashing/sha256
export conversation

const
  GrantDomain* = "muster.epoch.grant.v1"
  EnvelopeDomain* = "muster.envelope.v1"
  KeyIdDomain = "muster.epoch.key-id.v1"
  WireVersion = 2'u8
  MaxEpoch* = 0x7FFF_FFFF            ## no wrap: the 4-byte field stops here
  MaxEpochGap* = 16                  ## how far past the current epoch a grant may land (missed grants, out of order)
  MaxHeldGrants = 64

var RemovalGraceS* = 300.0   ## seconds a removed sender's in-flight envelopes are still taken (a test may shorten it)

type
  EpochKeyGrant* = object
    ## An epoch key handed over in process (tests, and a founder seeding peers it already
    ## trusts): the epoch, its member set, and the key wrapped to THIS member. Over the
    ## wire a grant is the signed record below, sealed whole to each member.
    epoch*: int
    members*: seq[Member]
    wrappedKey*: seq[byte]
    room*: string                       ## the room it is for, so the joiner signs and checks for it

  WireGrant = object
    epoch: int
    prev: array[32, byte]               ## the key id of the epoch this one follows
    members: seq[Member]
    key: array[32, byte]
    admitter: Member
    sig: Ed25519Sig

  AltKey = object
    ## a sibling epoch key that lost (or a key we hold only to read with)
    epoch: int
    key: array[32, byte]
    members: seq[Member]

  NotThisKey = object of SodiumError     ## the box does not open under this key (not a refusal)

  EpochCrypto* = ref object of ConversationCrypto
    ks: Keystore                          ## our identity — the secret stays behind this seam (FS-4)
    myEnc: Member                         ## our encryption identity (Ed25519 + X25519)
    room: string                          ## the content topic every grant and envelope signs (bindRoom)
    keys: Table[int, array[32, byte]]     ## the epochs I actually hold keys for
    memberSets: Table[int, seq[Member]]   ## members per epoch (for grants/queries)
    grantIds: Table[int, array[32, byte]] ## the digest of the signed grant each held epoch came from
    alts: seq[AltKey]                     ## losing siblings' keys, kept for opening
    joinKeys: Table[int, EncKeys]         ## per epoch, the join keypair derived from its key (cache)
    ownOnly: HashSet[int]                 ## epochs whose key I derived and have granted to no one (exo-7b3)
    leftAt: Table[Member, float]          ## when this member learned each removed member left
    expecting: bool                       ## a first grant is welcome (we asked to join, or hold nothing)
    expectFrom: seq[Member]               ## …only from these admitters, when set (an invite's sender)
    bannedFn: proc(): seq[Member] {.gcsafe.}  ## members the room removed; no new roster may name them
    refusing: bool                        ## an inbox: never takes a grant
    replaying*: bool                      ## frames from the member's own journal: accepted once already
    forkSeen*: seq[int]                   ## epochs where a second valid grant arrived
    cur: int

# ── ECIES via libsodium sealed boxes (X25519) ─────────────────────────────────
# A sealed box IS ECIES over X25519: ephemeral key + crypto_box AEAD to the
# recipient's X25519 key. Anonymous — the wrap names no sender, which is why the grant
# inside it carries the admitter's signature.

proc eciesWrap*(recipient: Member, secret: array[32, byte]): seq[byte] =
  sealTo(recipient.x, secret)

proc eciesUnwrapVia(ks: Keystore, wrapped: seq[byte]): array[32, byte] =
  let plain = ks.sealOpen(wrapped)
  if plain.len != 32:
    raise newException(SodiumError, "unwrapped key wrong length")
  for i in 0 ..< 32: result[i] = plain[i]

proc lessThan(a, b: array[32, byte]): bool =
  ## Bytewise order of two digests (a sibling's tie-break).
  for i in 0 ..< 32:
    if a[i] != b[i]: return a[i] < b[i]
  false

proc keyId(key: array[32, byte]): array[32, byte] =
  digest(hashInput(KeyIdDomain, @[("key", cbBytes(@key))]))

proc grantRecord(room: string, epoch: int, prev: array[32, byte], members: seq[Member],
                 key: array[32, byte], admitter: Member): HashInput =
  var ms: seq[CborValue]
  for m in members: ms.add cbBytes(m.toBytes())
  hashInput(GrantDomain, @[
    ("room", cbText(room)), ("epoch", cbInt(int64(epoch))), ("prev", cbBytes(@prev)),
    ("members", cbArray(ms)), ("key", cbBytes(@(keyId(key)))), ("admitter", cbBytes(admitter.toBytes()))])

proc envelopeRecord(room: string, epoch: int, payload: openArray[byte]): HashInput =
  hashInput(EnvelopeDomain, @[("room", cbText(room)), ("epoch", cbInt(int64(epoch))),
                              ("payload", cbBytes(@(sha256(payload))))])

# ── EpochCrypto ───────────────────────────────────────────────────────────────

method securityLevel*(cc: EpochCrypto): SecurityLevel =
  ## The epoch layer is the REAL confidentiality level for room data (exo-1ec.5): payloads
  ## are sealed to the current member set (ECIES over X25519 sealed boxes), and re-keying on
  ## every membership change means a later joiner cannot open an earlier epoch (F-16). Every
  ## envelope names and is signed by its sender, a member of its epoch (exo-3b3); it still
  ## does not attest provenance — that axis is the log's.
  securityLevel(
    axisLevel(rungReal, "every envelope signed by its sender, a member of its epoch"),
    axisLevel(rungNull, "no attestation from the crypto seam"),
    axisLevel(rungReal, "ECIES epoch (sealed box over X25519), forward-secret across epochs"))

proc newEpochCrypto*(ks: Keystore, room: string, others: seq[Member] = @[]): EpochCrypto =
  ## Found a conversation on `room` (its content topic): epoch 0, members = me + others.
  ## Its key is the keystore's founding key for the room — the same on every launch, so
  ## a restart reads everything sealed under it again (invariant 4), and no one else can
  ## derive it (F-16). Identity comes from the keystore; our secret never enters this layer.
  result = EpochCrypto(ks: ks, myEnc: ks.encIdentity(), room: room,
                       keys: initTable[int, array[32, byte]](),
                       memberSets: initTable[int, seq[Member]](), cur: 0)
  var members = @[result.myEnc]
  for m in others:
    if m != result.myEnc: members.add m
  result.keys[0] = ks.foundingKey(room)
  result.memberSets[0] = members
  if members.len == 1: result.ownOnly.incl 0

proc newEpochJoiner*(ks: Keystore, room = ""): EpochCrypto =
  ## A member who joins by ingesting grants; holds no key until they do, and takes the
  ## first grant from whoever admits it (it asked by being made: an inbox turns that off).
  EpochCrypto(ks: ks, myEnc: ks.encIdentity(), room: room, expecting: true,
              keys: initTable[int, array[32, byte]](),
              memberSets: initTable[int, seq[Member]](), cur: -1)

method bindRoom*(cc: EpochCrypto, room: string) =
  if cc.room.len == 0: cc.room = room

method expectGrant*(cc: EpochCrypto, fromMember: seq[Member] = @[]) =
  ## We asked to join (fromMember empty: anyone may admit us), or were invited by
  ## fromMember: a first grant from them is welcome while we hold no shared epoch.
  if cc.refusing: return
  if fromMember.len == 0: cc.expectFrom = @[]
  cc.expecting = true
  for m in fromMember:
    if m notin cc.expectFrom: cc.expectFrom.add m

method refuseGrants*(cc: EpochCrypto) =
  ## An inbox: a session here never joins anything, so no grant is ever taken.
  cc.expecting = false
  cc.refusing = true

method setReplaying*(cc: EpochCrypto, on: bool) = cc.replaying = on

proc setBanned*(cc: EpochCrypto, f: proc(): seq[Member] {.gcsafe.}) =
  ## Members the room has removed (a removal the chain executed, read from the log): no
  ## grant naming one is taken, so a removed member's own re-key never lands (exo-a16).
  cc.bannedFn = f

proc banned(cc: EpochCrypto): seq[Member] =
  if cc.bannedFn == nil or cc.replaying: return @[]
  try: cc.bannedFn() except CatchableError: @[]

proc epochsNewestFirst(cc: EpochCrypto): seq[int] =
  for e in cc.keys.keys: result.add e
  result.sort(Descending)

proc alone(cc: EpochCrypto): bool =
  ## Holding no epoch anyone else holds: a joiner, or a founder who admitted no one.
  cc.cur < 0 or cc.memberSets.getOrDefault(cc.cur) == @[cc.myEnc]

proc noteLeavers(cc: EpochCrypto, before, after: seq[Member]) =
  let now = epochTime()
  for m in before:
    if m notin after and m notin cc.leftAt: cc.leftAt[m] = (if cc.replaying: 0.0 else: now)
  for m in after: cc.leftAt.del m

proc grantFor*(cc: EpochCrypto, epoch: int, member: Member): EpochKeyGrant =
  ## Wrap an epoch's key to a member (the founder/driver hands these out). Only
  ## works for epochs this instance holds a key for.
  if epoch notin cc.keys:
    raise newException(SodiumError, "no key to grant for epoch " & $epoch)
  if member != cc.myEnc and epoch in cc.ownOnly:
    cc.ownOnly.excl epoch               # shared now: its join key is the shared one
    cc.joinKeys.del epoch
  EpochKeyGrant(epoch: epoch, members: cc.memberSets[epoch],
                wrappedKey: eciesWrap(member, cc.keys[epoch]), room: cc.room)

proc ingestGrant*(cc: EpochCrypto, grant: EpochKeyGrant) =
  ## Take an in-process grant (trusted: it never crossed the wire). Gives us exactly
  ## the epoch's envelopes — and only that epoch's (F-16), unless I was granted others.
  cc.keys[grant.epoch] = eciesUnwrapVia(cc.ks, grant.wrappedKey)
  if cc.room.len == 0: cc.room = grant.room
  cc.memberSets[grant.epoch] = grant.members
  cc.ownOnly.excl grant.epoch           # a granted key is shared; its join key follows it
  cc.joinKeys.del grant.epoch
  if grant.epoch > cc.cur: cc.cur = grant.epoch

proc advance(cc: EpochCrypto, members: seq[Member]) =
  ## Open the next epoch with a fresh key and this roster.
  let before = cc.memberSets.getOrDefault(cc.cur)
  let ne = cc.cur + 1
  if ne > MaxEpoch: raise newException(SodiumError, "the room has run out of epochs")
  cc.keys[ne] = randomKey()
  cc.memberSets[ne] = members
  cc.cur = ne
  cc.noteLeavers(before, members)

method addMember*(cc: EpochCrypto, member: Member) =
  var members = cc.memberSets.getOrDefault(cc.cur)
  if member notin members: members.add member
  cc.advance(members)

method removeMember*(cc: EpochCrypto, member: Member) =
  var members: seq[Member]
  for m in cc.memberSets.getOrDefault(cc.cur):
    if m != member: members.add m
  cc.advance(members)

proc openWith(cc: EpochCrypto, key: array[32, byte], epoch: int, members: seq[Member],
              envelope: seq[byte]): seq[byte] =
  ## Open under one key and check who sealed it: a signed envelope from a member of that
  ## epoch, still a member — or removed so recently that this was in flight — or replayed
  ## from our own journal. Raises otherwise.
  var plain: seq[byte]
  try: plain = secretboxOpen(key, envelope)
  except SodiumError: raise newException(NotThisKey, "not this key")
  if plain.len < 1 + 64 + 64 or plain[0] != WireVersion:
    raise newException(SodiumError, "an unsigned envelope")
  let sender = encIdentityFromBytes(plain[1 ..< 65])
  var sig: Ed25519Sig
  for i in 0 ..< 64: sig[i] = plain[65 + i]
  let payload = plain[129 .. ^1]
  if not edVerify(sender.ed, digest(envelopeRecord(cc.room, epoch, payload)), sig):
    raise newException(SodiumError, "an envelope its sender did not sign")
  if sender notin members:
    raise newException(SodiumError, "an envelope from someone who was not a member of its epoch")
  if not cc.replaying and sender != cc.myEnc and sender notin cc.memberSets.getOrDefault(cc.cur):
    let left = cc.leftAt.getOrDefault(sender, -1.0)
    if left < 0 or epochTime() - left > RemovalGraceS:
      raise newException(SodiumError, "an envelope from someone no longer in the room")
  payload

method seal*(cc: EpochCrypto, plaintext: seq[byte]): seq[byte] =
  if cc.cur notin cc.keys:
    raise newException(SodiumError, "no key for the current epoch")
  let sig = cc.ks.edSignRecord(envelopeRecord(cc.room, cc.cur, plaintext))
  var body = @[WireVersion] & cc.myEnc.toBytes()
  body.add sig
  body.add plaintext
  secretboxSeal(cc.keys[cc.cur], body)

method openedEpoch*(cc: EpochCrypto, envelope: seq[byte]): tuple[epoch: int, plain: seq[byte]] =
  ## Try every key we hold, newest first; the MAC tells us which (if any) sealed it, and
  ## the sender's signature that it is theirs, for that epoch.
  var why = "no epoch key we hold opens this envelope"
  for e in cc.epochsNewestFirst():
    try: return (e, cc.openWith(cc.keys[e], e, cc.memberSets.getOrDefault(e), envelope))
    except NotThisKey: discard
    except SodiumError as x: why = x.msg
  for a in cc.alts:
    try: return (a.epoch, cc.openWith(a.key, a.epoch, a.members, envelope))
    except NotThisKey: discard
    except SodiumError as x: why = x.msg
  raise newException(SodiumError, why)

method open*(cc: EpochCrypto, envelope: seq[byte]): seq[byte] =
  ## None opening means we joined after its epoch (F-16), it isn't this room's, or its
  ## sender may not speak in it.
  cc.openedEpoch(envelope).plain

method members*(cc: EpochCrypto): seq[Member] = cc.memberSets.getOrDefault(cc.cur)
method membersAt*(cc: EpochCrypto, epoch: int): seq[Member] =
  result = cc.memberSets.getOrDefault(epoch)
  for a in cc.alts:
    if a.epoch == epoch:
      for m in a.members:
        if m notin result: result.add m
method epoch*(cc: EpochCrypto): int = cc.cur

# ── membership handshake: signed grants, sealed whole ──────────────────────────
# Frame wire: a sealed box to the recipient's X25519 of
#   v(1)=2 ++ epoch(4 BE) ++ prev(32) ++ nMembers(2 BE) ++ members(64 each: ed25519 ++ x25519)
#   ++ epochKey(32) ++ admitter(64) ++ sig(64).
# The whole grant is sealed, not just the key (exo-661.7): a store node sees one anonymous
# sealed box per member of the new epoch — so it learns how many members the room has at
# each admit, and nothing about who they are. Inside, the admitter's signature (exo-3b3)
# says who re-keyed, for which room, from which epoch.

const MemberBytes = 64   # EncIdentity: ed25519(32) ++ x25519(32)


proc encodeGrant(g: WireGrant): seq[byte] =
  let e = g.epoch
  result = @[WireVersion, byte((e shr 24) and 0xFF), byte((e shr 16) and 0xFF),
             byte((e shr 8) and 0xFF), byte(e and 0xFF)]
  result.add g.prev
  result.add byte((g.members.len shr 8) and 0xFF)
  result.add byte(g.members.len and 0xFF)
  for m in g.members: result.add m.toBytes()
  result.add g.key
  result.add g.admitter.toBytes()
  result.add g.sig

proc decodeGrant(plain: seq[byte]): WireGrant =
  if plain.len < 1 + 4 + 32 + 2 + 32 + 64 + 64 or plain[0] != WireVersion:
    raise newException(SodiumError, "not a signed grant")
  result.epoch = (int(plain[1]) shl 24) or (int(plain[2]) shl 16) or (int(plain[3]) shl 8) or int(plain[4])
  for i in 0 ..< 32: result.prev[i] = plain[5 + i]
  let n = (int(plain[37]) shl 8) or int(plain[38])
  if plain.len != 39 + n * MemberBytes + 32 + 64 + 64:
    raise newException(SodiumError, "grant length does not match its roster")
  var off = 39
  for _ in 0 ..< n:
    result.members.add encIdentityFromBytes(plain[off ..< off + MemberBytes])
    off += MemberBytes
  for i in 0 ..< 32: result.key[i] = plain[off + i]
  off += 32
  result.admitter = encIdentityFromBytes(plain[off ..< off + MemberBytes])
  off += MemberBytes
  for i in 0 ..< 64: result.sig[i] = plain[off + i]

proc signedGrant(cc: EpochCrypto, epoch: int): WireGrant =
  ## The grant for an epoch I just opened, signed as its admitter.
  let prev = (if (epoch - 1) in cc.keys: keyId(cc.keys[epoch - 1]) else: default(array[32, byte]))
  result = WireGrant(epoch: epoch, prev: prev, members: cc.memberSets[epoch],
                     key: cc.keys[epoch], admitter: cc.myEnc)
  let rec = grantRecord(cc.room, epoch, prev, result.members, result.key, cc.myEnc)
  result.sig = cc.ks.edSignRecord(rec)
  cc.grantIds[epoch] = digest(rec)

method identity*(cc: EpochCrypto): Member = cc.myEnc

proc grantFrames(cc: EpochCrypto): seq[seq[byte]] =
  let g = cc.signedGrant(cc.cur)
  let plain = encodeGrant(g)
  for m in g.members:
    result.add sealTo(m.x, plain)

method admit*(cc: EpochCrypto, joiner: Member): seq[seq[byte]] =
  ## Admit a joiner: re-key forward to include them, then seal the signed grant to every
  ## member of the new epoch (the joiner and everyone already here — they all need the
  ## new key). The joiner gets ONLY this epoch's key, never earlier ones (F-16).
  cc.addMember(joiner)
  cc.grantFrames()

method expel*(cc: EpochCrypto, member: Member): seq[seq[byte]] =
  ## Remove a member: re-key forward without them, then seal the signed grant to every
  ## member who remains — the removed one receives no frame it can open (F-16 removal).
  cc.removeMember(member)
  cc.grantFrames()

proc take(cc: EpochCrypto, g: WireGrant, gid: array[32, byte]) =
  let before = cc.memberSets.getOrDefault(cc.cur)
  cc.keys[g.epoch] = g.key
  cc.memberSets[g.epoch] = g.members
  cc.grantIds[g.epoch] = gid
  cc.joinKeys.del g.epoch
  if g.epoch > cc.cur:
    cc.cur = g.epoch
    cc.noteLeavers(before, g.members)

proc keepAlt(cc: EpochCrypto, g: WireGrant) =
  for a in cc.alts:
    if a.epoch == g.epoch and a.key == g.key: return
  cc.alts.add AltKey(epoch: g.epoch, key: g.key, members: g.members)
  if cc.alts.len > MaxHeldGrants: cc.alts.delete(0)

method ingestControl*(cc: EpochCrypto, frame: seq[byte]): bool =
  ## Take a grant sealed to us, when it is one we may take (see the header). True when it
  ## changed what we hold — a new current epoch, an earlier epoch to read with, or a sibling
  ## key — false when it was not for us, not valid, or nothing new. Never raises.
  try:
    let g = decodeGrant(cc.ks.sealOpen(frame))
    if g.epoch < 1 or g.epoch > MaxEpoch: return false
    if cc.myEnc notin g.members or g.admitter notin g.members: return false
    if g.members.toHashSet().len != g.members.len: return false
    let rec = grantRecord(cc.room, g.epoch, g.prev, g.members, g.key, g.admitter)
    if not edVerify(g.admitter.ed, digest(rec), g.sig): return false
    let gid = digest(rec)
    for b in cc.banned():
      if b in g.members: return false
    let parent = g.epoch - 1
    let chained = parent in cc.keys and keyId(cc.keys[parent]) == g.prev and
                  g.admitter in cc.memberSets.getOrDefault(parent)
    if g.epoch in cc.keys:
      if cc.keys[g.epoch] == g.key: return false               # already held (R-2)
      if not chained: return false
      cc.forkSeen.add g.epoch
      # a sibling from the same parent: the smaller signed record is the epoch, on every
      # member that has not moved past it; the other key stays, to open what it sealed
      if g.epoch == cc.cur and cc.grantIds.hasKey(g.epoch) and lessThan(gid, cc.grantIds[g.epoch]):
        cc.alts.add AltKey(epoch: g.epoch, key: cc.keys[g.epoch], members: cc.memberSets[g.epoch])
        cc.take(g, gid)
      else:
        cc.keepAlt(g)
      return true
    if cc.refusing: return false
    if cc.replaying:
      cc.take(g, gid)
      return true
    if g.admitter == cc.myEnc:
      # a grant I signed myself, back from the store after a restart: mine, so taken
      cc.take(g, gid)
      return true
    if g.epoch < cc.cur:
      # an earlier epoch arriving late (out of order): kept to read with, when it chains
      if not chained: return false
      cc.take(g, gid)
      return true
    if cc.alone():
      if not cc.expecting: return false
      if cc.expectFrom.len > 0 and g.admitter notin cc.expectFrom: return false
      cc.take(g, gid)
      cc.expecting = false
      cc.expectFrom = @[]
      return true
    if g.epoch == cc.cur + 1 and chained:
      cc.take(g, gid)
      return true
    # missed grants (away for an epoch, or out of order): a member of our current epoch
    # may take us a short way forward
    if g.epoch > cc.cur and g.epoch <= cc.cur + MaxEpochGap and
       g.admitter in cc.memberSets.getOrDefault(cc.cur):
      cc.take(g, gid)
      return true
    false
  except CatchableError:
    false

# ── the room's join key (exo-661.7) ─────────────────────────────────────────────
# Each epoch's join keypair is derived from that epoch's key, so every member holding
# the key holds the join secret, a later joiner cannot derive an earlier epoch's (F-16),
# and nothing new is stored: it is rebuilt from the keys (invariant 4). The public half
# is the beacon; it is random-looking and names no member.
#
# Except an epoch only I hold — the one I founded, before I admit anyone (exo-7b3). Its
# key is my founding key, the same on every launch, so a join key derived from it would
# make my beacon the same on every launch: a pseudonym a store node could follow across
# my sessions, telling me apart from the room's other members. Its join keypair is drawn
# fresh for this instance instead. That loses nothing: a join request is not room state,
# and a requester reseals to the newest beacons until someone admits them.

proc joinKeysFor(cc: EpochCrypto, epoch: int): EncKeys =
  if epoch notin cc.joinKeys:
    let seed =
      if epoch in cc.ownOnly: randomKey()
      else: digest(hashInput("muster.room.join-key.v1", @[("epoch-key", cbBytes(@(cc.keys[epoch])))]))
    cc.joinKeys[epoch] = encFromSeed(seed)
  cc.joinKeys[epoch]

method joinBeacon*(cc: EpochCrypto): seq[byte] =
  if cc.cur notin cc.keys: return @[]
  @(cc.joinKeysFor(cc.cur).identity().x)

method ownsBeacon*(cc: EpochCrypto, beacon: seq[byte]): bool =
  for e in cc.epochsNewestFirst():
    if @(cc.joinKeysFor(e).identity().x) == beacon: return true

method sealJoinRequest*(cc: EpochCrypto, beacon, request: seq[byte]): seq[byte] =
  if beacon.len != 32: raise newException(SodiumError, "a join key is 32 bytes")
  var pk: X25519Pub
  for i in 0 ..< 32: pk[i] = beacon[i]
  sealTo(pk, request)

method openJoinRequest*(cc: EpochCrypto, frame: seq[byte]): seq[byte] =
  for e in cc.epochsNewestFirst():
    try: return cc.joinKeysFor(e).sealOpen(frame)
    except CatchableError: discard
  raise newException(SodiumError, "no join key we hold opens this request")


# ── frames as anyone could build them (adversarial tests, exo-3b3) ──────────────

proc keyIdOf*(key: array[32, byte]): array[32, byte] = keyId(key)

proc envelopeRecordOf*(room: string, epoch: int, payload: seq[byte]): HashInput =
  ## What an envelope's sender signs.
  envelopeRecord(room, epoch, payload)

proc grantFrameAs*(signer: Keystore, room: string, epoch: int, prev: array[32, byte],
                   members: seq[Member], key: array[32, byte], recipient: Member): seq[byte] =
  ## A grant signed by `signer` and sealed to `recipient`: what a member's admit sends, or
  ## what someone who is not one could try. The receiving side decides; this only builds.
  let admitter = signer.encIdentity()
  var g = WireGrant(epoch: epoch, prev: prev, members: members, key: key, admitter: admitter)
  g.sig = signer.edSignRecord(grantRecord(room, epoch, prev, members, key, admitter))
  sealTo(recipient.x, encodeGrant(g))

proc envelopeAs*(signer: Keystore, room: string, epoch: int, key: array[32, byte],
                 payload: seq[byte]): seq[byte] =
  ## An envelope sealed under `key` and signed by `signer` as sent in `epoch`.
  var body = @[WireVersion] & signer.encIdentity().toBytes()
  body.add signer.edSignRecord(envelopeRecord(room, epoch, payload))
  body.add payload
  secretboxSeal(key, body)

proc heldKey*(cc: EpochCrypto, epoch: int): array[32, byte] =
  ## The key of an epoch this member holds (tests: what a member — or a removed one — has).
  cc.keys[epoch]
