## The quest record program's on-chain objects, as muster reads and writes them (exo-267.7;
## docs/design/lez-quest-program.md; the program is programs/lez-quest).
##
## A quest is issued by an account — a circle's LEZ multisig vault, granted by its
## Execute, or a person's own — accepted by its taker's own signature, confirmed by its
## confirmer's, and closed by its issuer, the bounty held in the record account's native
## shard in between. This module is the program's data, not its execution:
##   * QuestRecord in the program's borsh layout, decoded whole: a truncated or padded
##     record is refused, never guessed;
##   * every instruction's borsh, as the room builds them into a multisig proposal's call
##     or a member's own transaction;
##   * the record's PDA, SHA-256("/lez-quest/v0.1/Record/" padded ‖ issuer ‖ quest id)
##     under LEZ's public-PDA formula (the v0.3 multisig's, psLee02).
## Held to vectors from the program's own crate (tests/vectors/lez-quest-v010).

import stint
import ../hashing/sha256
import ./multisig

type
  QuestStatusKind* = enum
    qsOpen = "open", qsAccepted = "accepted", qsConfirmed = "confirmed", qsClosed = "closed",
    qsCancelled = "cancelled"

  QuestRecord* = object
    issuer*: seq[byte]          ## 32: the issuing account (a multisig vault, or a person's)
    questId*: seq[byte]         ## 32
    termsHash*: seq[byte]       ## 32: the terms, hashed by the issuer; the text stays with them
    bounty*: UInt128            ## native LEZ held in the record account until Close or Cancel
    confirmer*: seq[byte]       ## 32
    namedTaker*: seq[byte]      ## 32, or empty: anyone but the confirmer may accept
    status*: QuestStatusKind
    statusTaker*: seq[byte]     ## 32 for accepted / confirmed / closed: who took it; else empty

const RecordDomain = "/lez-quest/v0.1/Record/"

proc pad32(s: string): seq[byte] =
  result = newSeq[byte](32)
  for i, c in s: result[i] = byte(c)

proc questRecordSeed*(issuer, questId: seq[byte]): seq[byte] =
  if issuer.len != 32 or questId.len != 32: raise newException(LezDecodeError, "a record seed takes a 32-byte issuer and quest id")
  @(sha256(pad32(RecordDomain) & issuer & questId))

proc questRecordPda*(scheme: PdaScheme, program, issuer, questId: seq[byte]): seq[byte] =
  ## Where the record lives, and the account holding its bounty.
  publicPda(scheme, program, questRecordSeed(issuer, questId))

# ── borsh ─────────────────────────────────────────────────────────────────────
proc bad(msg: string) {.noreturn.} = raise newException(LezDecodeError, msg)

proc put32(b: var seq[byte], x: seq[byte]) =
  if x.len != 32: bad("a 32-byte field is " & $x.len & " bytes")
  b.add x

proc putU128(b: var seq[byte], x: UInt128) = b.add @(x.toBytesLE())

proc putOpt32(b: var seq[byte], x: seq[byte]) =
  if x.len == 0: b.add 0'u8
  else: (b.add 1'u8; b.put32(x))

type Rd = object
  b: seq[byte]
  p: int

proc take(r: var Rd, n: int): seq[byte] =
  if r.p + n > r.b.len: bad("a quest record ends early")
  result = r.b[r.p ..< r.p + n]
  r.p += n

proc u8(r: var Rd): uint8 = r.take(1)[0]

proc u128(r: var Rd): UInt128 =
  var a: array[16, byte]
  let s = r.take(16)
  for i in 0 ..< 16: a[i] = s[i]
  UInt128.fromBytesLE(a)

proc encodeQuestRecord*(q: QuestRecord): seq[byte] =
  result.put32(q.issuer)
  result.put32(q.questId)
  result.put32(q.termsHash)
  result.putU128(q.bounty)
  result.put32(q.confirmer)
  result.putOpt32(q.namedTaker)
  result.add byte(ord(q.status))
  if q.status in {qsAccepted, qsConfirmed, qsClosed}: result.put32(q.statusTaker)

proc decodeQuestRecord*(b: openArray[byte]): QuestRecord =
  var r = Rd(b: @b)
  result.issuer = r.take(32)
  result.questId = r.take(32)
  result.termsHash = r.take(32)
  result.bounty = r.u128()
  result.confirmer = r.take(32)
  case r.u8()
  of 0: discard
  of 1: result.namedTaker = r.take(32)
  else: bad("a named taker is Option<[u8; 32]>")
  let s = r.u8()
  if s > ord(high(QuestStatusKind)): bad("unknown quest status " & $s)
  result.status = QuestStatusKind(s)
  if result.status in {qsAccepted, qsConfirmed, qsClosed}: result.statusTaker = r.take(32)
  if r.p != r.b.len: bad("a quest record carries " & $(r.b.len - r.p) & " bytes too many")

# ── instructions (borsh enum: the variant index, then its fields) ─────────────
proc questOpen*(questId, termsHash: seq[byte], bounty: UInt128, confirmer: seq[byte],
                taker: seq[byte] = @[]): seq[byte] =
  ## Issue a quest. Rows: [record, issuer] + with a bounty [issuer native, record native].
  result = @[0'u8]
  result.put32(questId)
  result.put32(termsHash)
  result.putU128(bounty)
  result.put32(confirmer)
  result.putOpt32(taker)

proc questAccept*(issuer, questId: seq[byte]): seq[byte] =
  ## The taker's own transaction. Rows: [record, taker].
  result = @[1'u8]
  result.put32(issuer)
  result.put32(questId)

proc questConfirm*(issuer, questId: seq[byte]): seq[byte] =
  ## The confirmer's own transaction. Rows: [record, confirmer].
  result = @[2'u8]
  result.put32(issuer)
  result.put32(questId)

proc questClose*(questId, taker: seq[byte], bounty: UInt128): seq[byte] =
  ## The issuer closes it, paying the taker. Rows: [record, issuer] + with a bounty
  ## [record native, taker native].
  result = @[3'u8]
  result.put32(questId)
  result.put32(taker)
  result.putU128(bounty)

proc questCancel*(questId: seq[byte], bounty: UInt128): seq[byte] =
  ## The issuer withdraws it before it is confirmed. Rows: [record, issuer] + with a
  ## bounty [record native, issuer native].
  result = @[4'u8]
  result.put32(questId)
  result.putU128(bounty)
