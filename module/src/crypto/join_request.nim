## A request to join a room (exo-a87): the encryption identity asking, and that identity's
## own Ed25519 signature over the room it asks to join and an expiry. The signature proves
## whoever asks holds the key they name, so no one can ask in another's name.
##
## It names no secp256k1 key. Entering a room discloses the encryption identity and nothing
## else (spec derived-exo-45e s2; docs/design/material-and-disclosure.md §4 rule 2): a
## member's authorization address reaches a room only through an act (an approval, whose
## signature names its signer; an address share; an account disclosure). Until 2026-10-11
## the request carried a LinkStatement signed by the member's one secp key, so every room
## they asked to join could recover that address, the same in every room.
##
## The signed bytes are a domain-separated hash-input record (invariant 5) committing to
## the identity, the room and the expiry (invariant 2's context: worthless for another room,
## stale on its own).

import ../dcbor/dcbor
import ../hashing/hash_input
import ./curve25519

type
  JoinRequest* = object
    enc*: EncIdentity    ## who asks: the encryption identity, and nothing else
    room*: string        ## the room (its content topic) the request is for
    expiry*: uint64      ## unix time; refused after this
    sig*: Ed25519Sig     ## enc.ed's signature over joinDigest

  JoinRequestError* = object of CatchableError

proc joinRecord*(enc: EncIdentity, room: string, expiry: uint64): HashInput =
  ## The record the encryption identity signs: both halves of the identity, the room and the
  ## expiry. Change any of them and the signature no longer verifies.
  hashInput("muster.join-request.v1", @[
    ("ed25519", cbBytes(@(enc.ed))),
    ("x25519", cbBytes(@(enc.x))),
    ("room", cbText(room)),
    ("expiry", cbUint(expiry)),
  ])

proc joinDigest*(enc: EncIdentity, room: string, expiry: uint64): array[32, byte] =
  ## What is signed: SHA-256 of `joinRecord`.
  digest(joinRecord(enc, room, expiry))

proc issueJoinRequest*(edSign: proc(msg: seq[byte]): Ed25519Sig {.closure.},
                       enc: EncIdentity, room: string, expiry: uint64): JoinRequest =
  ## Sign a request with whatever holds the Ed25519 key (a Keystore). The closure is the
  ## only thing that touches the secret.
  JoinRequest(enc: enc, room: room, expiry: expiry, sig: edSign(@(joinDigest(enc, room, expiry))))

proc joinRequestValid*(r: JoinRequest, room: string, now: uint64): bool =
  ## True when the request is for `room`, unexpired, and signed by the identity it names.
  r.room == room and now <= r.expiry and edVerify(r.enc.ed, joinDigest(r.enc, r.room, r.expiry), r.sig)

proc encodeJoinRequest*(r: JoinRequest): seq[byte] =
  ## Wire form inside the sealed frame: enc(64) ++ roomLen(2 BE) ++ room ++ expiry(8 BE)
  ## ++ sig(64). Fixed fields around one length-prefixed string, so nothing else fits in it.
  result = r.enc.toBytes()
  result.add byte((r.room.len shr 8) and 0xFF)
  result.add byte(r.room.len and 0xFF)
  for c in r.room: result.add byte(c)
  for i in countdown(7, 0): result.add byte((r.expiry shr (8 * i)) and 0xFF)
  for b in r.sig: result.add b

proc decodeJoinRequest*(b: seq[byte]): JoinRequest =
  ## Inverse of encodeJoinRequest. Raises on any other shape, an old secp-signed binding
  ## included (its 65-byte signature and extra slot field do not fit), so such a request
  ## is ignored, never read as a member's.
  if b.len < 64 + 2: raise newException(JoinRequestError, "join request truncated")
  let n = (int(b[64]) shl 8) or int(b[65])
  if b.len != 64 + 2 + n + 8 + 64: raise newException(JoinRequestError, "join request is not one request")
  result.enc = encIdentityFromBytes(b[0 ..< 64])
  for i in 0 ..< n: result.room.add char(b[66 + i])
  var off = 66 + n
  for i in 0 ..< 8: result.expiry = (result.expiry shl 8) or uint64(b[off + i])
  off += 8
  for i in 0 ..< 64: result.sig[i] = b[off + i]
