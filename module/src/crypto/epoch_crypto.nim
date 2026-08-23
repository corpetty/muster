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
import ./sodium
import ./curve25519
import ./conversation
import ./keystore
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

# ── membership handshake: sealed-box grants as the control frames ──────────────
# Frame wire: epoch(4 BE) ++ nMembers(2 BE) ++ member identities(64 each:
# ed25519 ++ x25519) ++ sealed box (the wrapped epoch key). The tail is exactly
# eciesWrap's output (a sealed box), so ingest reuses eciesUnwrapVia.

const MemberBytes = 64   # EncIdentity: ed25519(32) ++ x25519(32)

proc encodeGrant(g: EpochKeyGrant): seq[byte] =
  let e = g.epoch
  result = @[byte((e shr 24) and 0xFF), byte((e shr 16) and 0xFF),
             byte((e shr 8) and 0xFF), byte(e and 0xFF),
             byte((g.members.len shr 8) and 0xFF), byte(g.members.len and 0xFF)]
  for m in g.members: result.add m.toBytes()
  result.add g.wrappedKey

proc decodeGrant(frame: seq[byte]): EpochKeyGrant =
  if frame.len < 6: raise newException(SodiumError, "grant frame too short")
  result.epoch = (int(frame[0]) shl 24) or (int(frame[1]) shl 16) or
                 (int(frame[2]) shl 8) or int(frame[3])
  let n = (int(frame[4]) shl 8) or int(frame[5])
  var off = 6
  for _ in 0 ..< n:
    if off + MemberBytes > frame.len: raise newException(SodiumError, "grant frame truncated")
    result.members.add encIdentityFromBytes(frame[off ..< off + MemberBytes])
    off += MemberBytes
  result.wrappedKey = frame[off .. ^1]

method identity*(cc: EpochCrypto): Member = cc.myEnc

method admit*(cc: EpochCrypto, joiner: Member): seq[seq[byte]] =
  ## Re-key forward to include the joiner, then wrap the new epoch key to every
  ## member of the new epoch (the joiner and everyone who was already here — they
  ## all need the new key). The joiner gets ONLY this epoch's key, never earlier
  ## ones (F-16). A frame each member cannot open is simply ignored by them.
  cc.addMember(joiner)
  let ne = cc.cur
  for m in cc.memberSets[ne]:
    result.add encodeGrant(cc.grantFor(ne, m))

method ingestControl*(cc: EpochCrypto, frame: seq[byte]): bool =
  ## Try to open a grant addressed to us. Wrong-recipient frames fail the ECIES
  ## unwrap (a raise) and are reported as "not for me" rather than propagated.
  try:
    let g = decodeGrant(frame)
    if g.epoch in cc.keys: return false      # already hold it — idempotent (R-2)
    cc.ingestGrant(g)
    g.epoch in cc.keys
  except CatchableError:
    false
