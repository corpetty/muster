## Author-signed events (exo-f76) — what the room says a member did is only what
## that member signed (invariant 9).
##
## A log event is sealed to the room under the membership epoch key, which proves a
## member sent it but not which one. Most kinds need no more: an approval is verified
## by its driver, an attestation and a key binding carry their own signatures, and the
## rest (propose, policy, context, submit, final, membership) name no author. Five kinds
## name their author with a plain string, and a view reads that string back as "who did
## it":
##
##   message/<id>                         the author is the value's "author"
##   intent/<id>/decline/<who>            the card's Deny
##   intent/<id>/material/<req>/<who>     a material share
##   account/<caip10>/disclose/<who>      an account disclosure
##   frost/<cid>/join/<who>               a FROST ceremony join
##
## Each of those carries `authorSig`: the named author's Ed25519 signature (the
## encryption identity's signing half, F-14) over a domain-separated hash-input record
## of (room topic, key, parents, author, the value's dCBOR without the signature). So a
## signature binds to one room (a genuine event replayed into another room fails, as
## invariant 2 asks of every signature), to one exact event (an edited body or new
## parents fail), and to one author (only that member's key verifies). The value is
## hashed as dCBOR, not as JSON text: two JSON spellings of the same value sign the same,
## and a float anywhere in it refuses (invariant 5).
##
## `authenticEvents` is the read path: it drops an author-bearing event whose
## signature does not verify and passes every other event through untouched. The log
## itself keeps whatever it received — a forgery stays in the raw log, where a proof
## can still account for it — and state is reduce(authenticEvents(log)), still a pure
## function of log + room (invariant 4). Classification is by the key's kind segment,
## not its exact shape, so no key a fold would read as author-bearing slips through
## unclassified. Nothing here raises on a hostile event (exo-cf7): it is dropped.

import std/[json, strutils, tables, algorithm]
import ../log/log
import ../dcbor/dcbor
import ../hashing/hash_input
import ../crypto/curve25519
import ../crypto/keystore
import ./session

const
  AuthorDomain* = "muster.event.author.v1"
  AuthorSigField* = "authorSig"

type AuthorshipError* = object of CatchableError

proc normHex(s: string): string =
  result = s.toLowerAscii()
  if result.startsWith("0x"): result = result[2 .. ^1]

proc unhex(s: string): seq[byte] =
  ## Strict: an odd length or a non-hex character is empty (never a raise).
  let h = normHex(s)
  if h.len mod 2 != 0: return @[]
  for i in 0 ..< h.len div 2:
    var b = 0
    for c in h[2*i .. 2*i+1]:
      let d = (case c
               of '0'..'9': ord(c) - ord('0')
               of 'a'..'f': ord(c) - ord('a') + 10
               else: -1)
      if d < 0: return @[]
      b = b * 16 + d
    result.add byte(b)

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc cborOfJson(j: JsonNode): CborValue =
  ## A JSON value as dCBOR, so the signed bytes do not depend on JSON spelling. dCBOR
  ## has no place for a float on a signing path (invariant 5): one refuses.
  case j.kind
  of JObject:
    var pairs: seq[(CborValue, CborValue)]
    for k, v in j: pairs.add (cbText(k), cborOfJson(v))
    cbMap(pairs)
  of JArray:
    var items: seq[CborValue]
    for v in j: items.add cborOfJson(v)
    cbArray(items)
  of JString: cbText(j.getStr())
  of JInt: cbInt(j.getBiggestInt())
  of JBool: cbBool(j.getBool())
  of JNull: cbNull()
  of JFloat: raise newException(AuthorshipError, "a float has no canonical form on a signing path")

proc authorOf*(e: Event): tuple[authored: bool, author: string] =
  ## Whether this event's kind names an author, and the author it names ("" when the
  ## key is too short to name one — still author-bearing, so it can never verify).
  let p = e.key.split('/')
  if p[0] == "message":
    var author = ""
    try:
      let j = parseJson(e.value)
      if j.kind == JObject: author = j{"author"}.getStr()
    except CatchableError: discard
    return (true, author)
  if p.len >= 3:
    if p[0] == "intent" and p[2] == "decline": return (true, (if p.len >= 4: p[3] else: ""))
    if p[0] == "intent" and p[2] == "material": return (true, (if p.len >= 5: p[4] else: ""))
    if p[0] == "account" and p[2] == "disclose": return (true, (if p.len >= 4: p[3] else: ""))
    if p[0] == "frost" and p[2] == "join": return (true, (if p.len >= 4: p[3] else: ""))
  (false, "")

proc claimOf(room: string, e: Event, author: string, body: JsonNode): HashInput =
  var parents = e.parents
  sort(parents)
  var ps: seq[CborValue]
  for p in parents: ps.add cbText(p)
  var unsigned = newJObject()
  for k, v in body:
    if k != AuthorSigField: unsigned[k] = v
  hashInput(AuthorDomain, @[
    ("room", cbText(room)),
    ("key", cbText(e.key)),
    ("parents", cbArray(ps)),
    ("author", cbText(normHex(author))),
    ("value", cborOfJson(unsigned)),
  ])

proc bodyOf(e: Event): JsonNode =
  ## The event's value as a JSON object, or raise: every author-bearing kind carries one.
  let j = parseJson(e.value)
  if j.kind != JObject: raise newException(AuthorshipError, "an author-bearing value is a JSON object")
  j

proc authorDigest*(room: string, e: Event): array[32, byte] =
  ## What the author signs for `e` in `room` (its signature field ignored). Raises on
  ## an event that cannot carry an author signature.
  let (authored, author) = authorOf(e)
  if not authored: raise newException(AuthorshipError, "not an author-bearing event: " & e.key)
  digest(claimOf(room, e, author, bodyOf(e)))

proc signAuthored*(ks: Keystore, room: string, e: Event): Event =
  ## `e` with its author's signature added. Only the author can sign: an event naming
  ## anyone but this keystore's encryption identity is refused.
  let (authored, author) = authorOf(e)
  if not authored: raise newException(AuthorshipError, "not an author-bearing event: " & e.key)
  if normHex(author) != hexOf(ks.encIdentity().toBytes()):
    raise newException(AuthorshipError, "an event can only be signed by the member it names")
  var body = bodyOf(e)
  body[AuthorSigField] = %hexOf(ks.edSign(digest(claimOf(room, e, author, body))))
  Event(parents: e.parents, key: e.key, value: $body)

proc authorVerified*(room: string, e: Event): bool =
  ## An author-bearing event's signature verifies against the author it names, in this
  ## room. Anything malformed is false, never a raise.
  try:
    let (authored, author) = authorOf(e)
    if not authored: return false
    let id = unhex(author)
    if id.len != 64: return false
    let body = bodyOf(e)
    if not body.hasKey(AuthorSigField) or body[AuthorSigField].kind != JString: return false
    let sigBytes = unhex(body[AuthorSigField].getStr())
    if sigBytes.len != 64: return false
    var sig: Ed25519Sig
    for i in 0 ..< 64: sig[i] = sigBytes[i]
    let d = digest(claimOf(room, e, author, body))
    edVerify(encIdentityFromBytes(id).ed, d, sig)
  except CatchableError:
    false

proc authenticEvents*(events: seq[Event], room: string): seq[Event] =
  ## The events a room's views may read: every author-bearing event whose author signed
  ## it, and every event that names no author.
  for e in events:
    if not authorOf(e).authored or authorVerified(room, e): result.add e

proc roomEvents*(s: CoordinationSession): seq[Event] =
  ## The session's log as the room's views read it: `authenticEvents` over the raw log,
  ## with each verdict cached by event id (a pure function of the room and the event).
  for e in s.log.allEvents():
    if not authorOf(e).authored:
      result.add e
      continue
    let id = eventId(e)
    var ok = s.authorChecked.getOrDefault(id, false)
    if id notin s.authorChecked:
      ok = authorVerified(s.topic, e)
      s.authorChecked[id] = ok
    if ok: result.add e

proc publishAuthored*(s: CoordinationSession, ks: Keystore, e: Event) =
  ## Sign an author-bearing event as this member, for this room, and publish it.
  s.publish(signAuthored(ks, s.topic, e))
