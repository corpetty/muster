## EpochCrypto — the F-16 stopgap behind ConversationCrypto (ADR-010, amended).
##
## Per-conversation membership epochs. Each epoch has a fresh symmetric key that
## seals envelopes (AEAD, libsodium); the key is ECIES-wrapped to each member's
## secp256k1 public key — the SAME key they sign with, no second identity. A
## membership change opens a new epoch, so:
##   • a member added at epoch N receives ONLY epoch N's key → cannot open any
##     envelope sealed at an earlier epoch (F-16 forward secrecy for joiners);
##   • a member removed at epoch N is absent from epoch N+1 and never receives its
##     key → cannot open anything sent after removal (F-16 removal).
##
## Explicitly a stopgap: native logos-chat-module (MLS) provides this once it ships
## persistence + removal; it binds the SAME ConversationCrypto interface and this
## file is deleted. Kept thin for exactly that reason.
##
## ECIES wire: ephemeralPub(33) ++ nonce(24) ++ (MAC(16) ++ ciphertext).
## Envelope wire: epoch(4, big-endian) ++ secretbox(epochKey, plaintext).

import std/tables
import ./secp256k1
import ./sodium
import ./conversation
export conversation

type
  EpochKeyGrant* = object
    ## What a member is handed to participate in an epoch: the epoch index, its
    ## member set, and the epoch key ECIES-wrapped to THIS member. In the live
    ## system a grant is published (sealed) over the Transport; here it is a value
    ## the founder produces and the joiner ingests.
    epoch*: int
    members*: seq[Member]
    wrappedKey*: seq[byte]

  EpochCrypto* = ref object of ConversationCrypto
    mySec: array[32, byte]
    myPub: Member
    keys: Table[int, array[32, byte]]     ## the epochs I actually hold keys for
    memberSets: Table[int, seq[Member]]   ## members per epoch (for grants/queries)
    cur: int

# ── ECIES over secp256k1 + libsodium ──────────────────────────────────────────

proc randomSeckey(): array[32, byte] =
  ## A uniformly random valid secp256k1 secret key (retry the vanishingly rare
  ## out-of-range draw).
  while true:
    result = randomKey()
    try:
      discard pubKeyOf(result)
      return
    except Secp256k1Error:
      discard

proc eciesWrap*(recipient: Member, secret: array[32, byte]): seq[byte] =
  ## Encrypt `secret` (an epoch key) to a recipient's public key. Ephemeral-static
  ## ECDH derives the AEAD key; only the recipient's private key can unwrap it.
  let ephSec = randomSeckey()
  let ephPub = pubKeyOf(ephSec)
  let shared = ecdh(ephSec, recipient)
  @ephPub & secretboxSeal(shared, secret)

proc eciesUnwrap*(mySec: array[32, byte], wrapped: seq[byte]): array[32, byte] =
  if wrapped.len < 33:
    raise newException(SodiumError, "wrapped key too short")
  var ephPub: PubKey
  for i in 0 ..< 33: ephPub[i] = wrapped[i]
  let shared = ecdh(mySec, ephPub)
  let plain = secretboxOpen(shared, wrapped[33 .. ^1])
  if plain.len != 32:
    raise newException(SodiumError, "unwrapped key wrong length")
  for i in 0 ..< 32: result[i] = plain[i]

# ── EpochCrypto ───────────────────────────────────────────────────────────────

proc newEpochCrypto*(mySec: array[32, byte], others: seq[Member] = @[]): EpochCrypto =
  ## Found a conversation: epoch 0 with a fresh key I hold, members = me + others.
  result = EpochCrypto(mySec: mySec, myPub: pubKeyOf(mySec),
                       keys: initTable[int, array[32, byte]](),
                       memberSets: initTable[int, seq[Member]](), cur: 0)
  var members = @[result.myPub]
  for m in others:
    if m != result.myPub: members.add m
  result.keys[0] = randomKey()
  result.memberSets[0] = members

proc newEpochJoiner*(mySec: array[32, byte]): EpochCrypto =
  ## A member who joins by ingesting grants; holds no key until they do.
  EpochCrypto(mySec: mySec, myPub: pubKeyOf(mySec),
              keys: initTable[int, array[32, byte]](),
              memberSets: initTable[int, seq[Member]](), cur: -1)

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
  cc.keys[grant.epoch] = eciesUnwrap(cc.mySec, grant.wrappedKey)
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
  let hdr = [byte((cc.cur shr 24) and 0xFF), byte((cc.cur shr 16) and 0xFF),
             byte((cc.cur shr 8) and 0xFF), byte(cc.cur and 0xFF)]
  @hdr & secretboxSeal(cc.keys[cc.cur], plaintext)

method open*(cc: EpochCrypto, envelope: seq[byte]): seq[byte] =
  if envelope.len < 4:
    raise newException(SodiumError, "envelope too short")
  let ep = (int(envelope[0]) shl 24) or (int(envelope[1]) shl 16) or
           (int(envelope[2]) shl 8) or int(envelope[3])
  if ep notin cc.keys:
    # We hold no key for this epoch — we joined after it (F-16), or it isn't ours.
    raise newException(SodiumError, "no key for epoch " & $ep)
  secretboxOpen(cc.keys[ep], envelope[4 .. ^1])

method members*(cc: EpochCrypto): seq[Member] = cc.memberSets.getOrDefault(cc.cur)
method epoch*(cc: EpochCrypto): int = cc.cur
