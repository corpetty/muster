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
## Envelope wire: secretbox(epochKey, plaintext) = nonce(24) ++ MAC(16) ++ ciphertext.
## No epoch number rides in the clear (exo-661.7): a reader tries the keys it holds,
## newest first, and the one whose MAC verifies is the envelope's epoch. A store node
## sees a random nonce and ciphertext, the same shape in every epoch.

import std/[algorithm, tables]
import ./sodium
import ./curve25519
import ./conversation
import ./keystore
import ../dcbor/dcbor
import ../hashing/hash_input
export conversation

type
  EpochKeyGrant* = object
    ## What a member is handed to participate in an epoch: the epoch index, its
    ## member set, and the epoch key wrapped to THIS member. In the live system a
    ## grant is published (as an opaque control frame) over the Transport; here it
    ## is a value the founder produces and the joiner ingests.
    epoch*: int
    members*: seq[Member]
    wrappedKey*: seq[byte]

  EpochCrypto* = ref object of ConversationCrypto
    ks: Keystore                          ## our identity — the secret stays behind this seam (FS-4)
    myEnc: Member                         ## our encryption identity (Ed25519 + X25519)
    keys: Table[int, array[32, byte]]     ## the epochs I actually hold keys for
    memberSets: Table[int, seq[Member]]   ## members per epoch (for grants/queries)
    joinKeys: Table[int, EncKeys]         ## per epoch, the join keypair derived from its key (cache)
    cur: int

# ── ECIES via libsodium sealed boxes (X25519) ─────────────────────────────────
# A sealed box IS ECIES over X25519: ephemeral key + crypto_box AEAD to the
# recipient's X25519 key. Anonymous — the wrap names no sender. Wrapping needs
# only the recipient's public X25519; unwrapping goes through the keystore seam,
# so our secret never enters this layer (a Keycard would unwrap on-card).

proc eciesWrap*(recipient: Member, secret: array[32, byte]): seq[byte] =
  sealTo(recipient.x, secret)

proc eciesUnwrapVia(ks: Keystore, wrapped: seq[byte]): array[32, byte] =
  let plain = ks.sealOpen(wrapped)
  if plain.len != 32:
    raise newException(SodiumError, "unwrapped key wrong length")
  for i in 0 ..< 32: result[i] = plain[i]

# ── EpochCrypto ───────────────────────────────────────────────────────────────

method securityLevel*(cc: EpochCrypto): SecurityLevel =
  ## The epoch layer is the REAL confidentiality level for room data (exo-1ec.5): payloads
  ## are sealed to the current member set (ECIES over X25519 sealed boxes), and re-keying on
  ## every membership change means a later joiner cannot open an earlier epoch (F-16). It
  ## still does not authenticate the speaker or attest provenance — those axes stay null.
  securityLevel(
    axisLevel(rungNull, "speaker not authenticated by the crypto seam"),
    axisLevel(rungNull, "no attestation from the crypto seam"),
    axisLevel(rungReal, "ECIES epoch (sealed box over X25519), forward-secret across epochs (F-16)"))

proc newEpochCrypto*(ks: Keystore, others: seq[Member] = @[]): EpochCrypto =
  ## Found a conversation: epoch 0 with a fresh key I hold, members = me + others.
  ## Identity comes from the keystore; our secret never enters this layer.
  result = EpochCrypto(ks: ks, myEnc: ks.encIdentity(),
                       keys: initTable[int, array[32, byte]](),
                       memberSets: initTable[int, seq[Member]](), cur: 0)
  var members = @[result.myEnc]
  for m in others:
    if m != result.myEnc: members.add m
  result.keys[0] = randomKey()
  result.memberSets[0] = members

proc newEpochJoiner*(ks: Keystore): EpochCrypto =
  ## A member who joins by ingesting grants; holds no key until they do.
  EpochCrypto(ks: ks, myEnc: ks.encIdentity(),
              keys: initTable[int, array[32, byte]](),
              memberSets: initTable[int, seq[Member]](), cur: -1)

proc epochsNewestFirst(cc: EpochCrypto): seq[int] =
  for e in cc.keys.keys: result.add e
  result.sort(Descending)

proc grantFor*(cc: EpochCrypto, epoch: int, member: Member): EpochKeyGrant =
  ## Wrap an epoch's key to a member (the founder/driver hands these out). Only
  ## works for epochs this instance holds a key for.
  if epoch notin cc.keys:
    raise newException(SodiumError, "no key to grant for epoch " & $epoch)
  EpochKeyGrant(epoch: epoch, members: cc.memberSets[epoch],
                wrappedKey: eciesWrap(member, cc.keys[epoch]))

proc ingestGrant*(cc: EpochCrypto, grant: EpochKeyGrant) =
  ## Receive an epoch key wrapped to me. After this I can open that epoch's
  ## envelopes — and only that epoch's (F-16), unless I was granted others.
  cc.keys[grant.epoch] = eciesUnwrapVia(cc.ks, grant.wrappedKey)
  cc.memberSets[grant.epoch] = grant.members
  if grant.epoch > cc.cur: cc.cur = grant.epoch

method addMember*(cc: EpochCrypto, member: Member) =
  let ne = cc.cur + 1
  var members = cc.memberSets.getOrDefault(cc.cur)
  if member notin members: members.add member
  cc.keys[ne] = randomKey()
  cc.memberSets[ne] = members
  cc.cur = ne

method removeMember*(cc: EpochCrypto, member: Member) =
  let ne = cc.cur + 1
  var members: seq[Member]
  for m in cc.memberSets.getOrDefault(cc.cur):
    if m != member: members.add m
  cc.keys[ne] = randomKey()
  cc.memberSets[ne] = members
  cc.cur = ne

method seal*(cc: EpochCrypto, plaintext: seq[byte]): seq[byte] =
  if cc.cur notin cc.keys:
    raise newException(SodiumError, "no key for the current epoch")
  secretboxSeal(cc.keys[cc.cur], plaintext)

method open*(cc: EpochCrypto, envelope: seq[byte]): seq[byte] =
  ## Try every key we hold, newest first; the MAC tells us which (if any) sealed it.
  ## None opening means we joined after its epoch (F-16) or it isn't this room's.
  for e in cc.epochsNewestFirst():
    try: return secretboxOpen(cc.keys[e], envelope)
    except SodiumError: discard
  raise newException(SodiumError, "no epoch key we hold opens this envelope")

method members*(cc: EpochCrypto): seq[Member] = cc.memberSets.getOrDefault(cc.cur)
method epoch*(cc: EpochCrypto): int = cc.cur

# ── membership handshake: sealed-box grants as the control frames ──────────────
# Frame wire: a sealed box to the recipient's X25519 of
#   epoch(4 BE) ++ nMembers(2 BE) ++ member identities(64 each: ed25519 ++ x25519) ++ epochKey(32).
# The whole grant is sealed, not just the key (exo-661.7): the roster and the epoch
# number used to ride in the clear, once per member, on every admit. A store node now
# sees one anonymous sealed box per member of the new epoch — so it learns how many
# members the room has at each admit, and nothing about who they are.

const MemberBytes = 64   # EncIdentity: ed25519(32) ++ x25519(32)

proc encodeGrantPlain(epoch: int, members: seq[Member], key: array[32, byte]): seq[byte] =
  result = @[byte((epoch shr 24) and 0xFF), byte((epoch shr 16) and 0xFF),
             byte((epoch shr 8) and 0xFF), byte(epoch and 0xFF),
             byte((members.len shr 8) and 0xFF), byte(members.len and 0xFF)]
  for m in members: result.add m.toBytes()
  result.add key

proc decodeGrantPlain(plain: seq[byte]): tuple[epoch: int, members: seq[Member], key: array[32, byte]] =
  if plain.len < 6 + 32: raise newException(SodiumError, "grant too short")
  result.epoch = (int(plain[0]) shl 24) or (int(plain[1]) shl 16) or
                 (int(plain[2]) shl 8) or int(plain[3])
  let n = (int(plain[4]) shl 8) or int(plain[5])
  if plain.len != 6 + n * MemberBytes + 32: raise newException(SodiumError, "grant length does not match its roster")
  var off = 6
  for _ in 0 ..< n:
    result.members.add encIdentityFromBytes(plain[off ..< off + MemberBytes])
    off += MemberBytes
  for i in 0 ..< 32: result.key[i] = plain[off + i]

method identity*(cc: EpochCrypto): Member = cc.myEnc

method admit*(cc: EpochCrypto, joiner: Member): seq[seq[byte]] =
  ## Re-key forward to include the joiner, then wrap the new epoch key to every
  ## member of the new epoch (the joiner and everyone who was already here — they
  ## all need the new key). The joiner gets ONLY this epoch's key, never earlier
  ## ones (F-16). A frame each member cannot open is simply ignored by them.
  cc.addMember(joiner)
  let ne = cc.cur
  let plain = encodeGrantPlain(ne, cc.memberSets[ne], cc.keys[ne])
  for m in cc.memberSets[ne]:
    result.add sealTo(m.x, plain)

method ingestControl*(cc: EpochCrypto, frame: seq[byte]): bool =
  ## Try to open a grant addressed to us. A frame sealed to someone else fails to
  ## open through our keystore (a raise) and is reported as "not for me".
  try:
    let g = decodeGrantPlain(cc.ks.sealOpen(frame))
    if g.epoch in cc.keys: return false      # already hold it — idempotent (R-2)
    cc.keys[g.epoch] = g.key
    cc.memberSets[g.epoch] = g.members
    if g.epoch > cc.cur: cc.cur = g.epoch
    true
  except CatchableError:
    false

# ── the room's join key (exo-661.7) ─────────────────────────────────────────────
# Each epoch's join keypair is derived from that epoch's key, so every member holding
# the key holds the join secret, a later joiner cannot derive an earlier epoch's (F-16),
# and nothing new is stored: it is rebuilt from the keys (invariant 4). The public half
# is the beacon; it is random-looking and names no member.

proc joinKeysFor(cc: EpochCrypto, epoch: int): EncKeys =
  if epoch notin cc.joinKeys:
    let seed = digest(hashInput("muster.room.join-key.v1", @[("epoch-key", cbBytes(@(cc.keys[epoch])))]))
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
