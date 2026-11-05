## Voice notes in the room (docs/design/voice-notes.md §3.3, §6, §7): a note as two log
## events, folded by `reduceVoice` into notes, and merged with the room's messages into the
## thread's rows by `threadRows`.
##
##   voice/<nid>/<author>/<i>/2   one half of the note's clip record (i ∈ {0, 1}), in its
##                                author's name: {"v":1, "ts", "durMs", "digest", "part",
##                                "authorSig"}, the half as base64, every number an integer
##
## Each part is author-signed (authorship.nim reads its author off the key) and published
## through `publishAuthored`; `session.publish` pads every `voice/` frame to VoiceFrameBytes
## itself (§4), so no caller passes a pad. The note id is content-addressed over (author,
## clip digest, ts), so every member derives it and nobody can post under another member's
## note id (§6 rule 4).
##
## The fold is pure and order-free (invariant 4), and links no codec: it imports only the
## clip record's structural checks (audio/voice_clip), never libopus or a device. Pass it the
## room's authentic view (`roomEvents(s)`): it trusts that every part's author signed it
## (§6 rule 1) and checks the rest itself. A malformed part is dropped, never raised on.
##
## It runs in two passes. The header pass reads each part's key and value and checks its
## shape, the half's base64 spelling included, but decodes nothing; it decides which parts
## stand and which notes are kept, and is all `threadLastTs` needs. The verdict pass judges
## a note of two parts: it decodes the halves, checks their agreement, the digest and the
## record. A part's header fields are a pure function of its event id, and a verdict of the
## two standing parts' ids, so a `VoiceMemo` the hosted layer keeps per room holds both
## across reads (§6): a read parses no part it has read before and judges no pair twice.
## The memo keeps no half: a verdict or a decode reads one back from its event. The room's
## other folds take the same memo (the flow, provenance and the room map, whose content of a
## part, `voiceContentOf`, is read off its header), so none of them parses a part again.
##
## Only `threadRows` makes a voice row, and the row carries the note in a field of its own,
## `voice`, never in `body` (§7): `reduceMessages` builds a row from a message's author, ts
## and body alone, so no `message/` event can put a `voice` field on a row, whatever its body
## claims. The audio never rides a row: `voice` is metadata only.

import std/[json, strutils, tables, algorithm, base64]
import ../log/log
import ../dcbor/dcbor
import ../hashing/hash_input
import ../audio/voice_clip
import ./intent_events

const
  NoteIdDomain* = "muster.voice.note-id.v1"
  ClipDigestDomain* = "muster.voice.clip.v1"
  VoiceEventVersion* = 1        ## the value's "v"; a new wire shape is a new version
  VoiceParts* = 2               ## a note is exactly two parts, whatever its length (§3.4)
  VoiceMinMs* = 500             ## a shorter note is refused at Send, `too-short` (§3.4, §8)
  PartFields = ["v", "ts", "durMs", "digest", "part", "authorSig"]

type
  VoiceState* = enum
    vsArriving = "arriving"     ## one part so far
    vsComplete = "complete"     ## both parts, every check passed: only this plays
    vsBroken = "broken"         ## the parts disagree, the digest misses, or the record fails
  VoiceNote* = object
    nid*: string                ## the note id (32 hex)
    author*: string             ## the key's author: the member whose signature the room verified
    ts*: int64                  ## the author's clock at Send (seconds)
    durMs*: int                 ## the clip's length, as its parts state it
    state*: VoiceState
    parts*: array[VoiceParts, EventId]  ## the standing parts' event ids ("" for one not yet in)
  ThreadRow* = object
    ## One row of the room's thread: a message, or a note. Only `threadRows` sets `isVoice`.
    id*: string                 ## a message's id, or a note's nid
    author*: string
    ts*: int64
    body*: string               ## a message's body; "" for a note
    isVoice*: bool
    note*: VoiceNote            ## the note, for a voice row

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc isLowerHex(s: string, n: int): bool =
  s.len == n and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc unhex(s: string): seq[byte] =
  ## Strict: anything but an even run of hex digits is empty.
  if s.len mod 2 != 0 or not s.allCharsInSet(HexDigits): return @[]
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))

proc clipDigest*(record: openArray[byte]): Sha256Digest =
  ## The clip's digest (§3.2): a domain-separated hash-input record over the record's bytes.
  digest(hashInput(ClipDigestDomain, @[("clip", cbBytes(@record))]))

proc noteIdOf*(author, clipHex: string, ts: int64): string =
  ## The note id every member derives (§3.3): 16 bytes (32 hex) of a hash-input record over
  ## the author's identity, the clip digest (`clipDigest`, as hex) and the note's ts.
  let d = digest(hashInput(NoteIdDomain, @[("author", cbText(author.toLowerAscii)),
                                           ("clip", cbBytes(unhex(clipHex.toLowerAscii))),
                                           ("ts", cbInt(ts))]))
  hexOf(d[0 ..< 16])

proc voiceKey*(nid, author: string, i: int): string =
  "voice/" & nid & "/" & author & "/" & $i & "/" & $VoiceParts

proc voicePartEvents*(author: string, record: seq[byte], ts: int64,
                      durMs: int): tuple[nid: string, events: seq[Event]] =
  ## A note's two parts for any record bytes, unsigned: the first half (the larger) in part
  ## 0, the rest in part 1. `voiceEvents` is what a client sends; this one also builds, from
  ## bytes that are no clip, the parts a fold must refuse. Raises ValueError unless `author`
  ## is a member's identity (128 hex).
  let a = author.toLowerAscii
  if not isLowerHex(a, 128): raise newException(ValueError, "not a member identity: " & author)
  let dg = hexOf(clipDigest(record))
  result.nid = noteIdOf(a, dg, ts)
  let half = (record.len + 1) div 2
  for i, span in [(0, half), (half, record.len)]:
    let (lo, hi) = span
    result.events.add Event(key: voiceKey(result.nid, a, i),
                            value: $(%*{"v": VoiceEventVersion, "ts": ts, "durMs": durMs,
                                        "digest": dg, "part": encode(record[lo ..< hi])}))

proc voiceEvents*(author: string, clip: VoiceClip, ts: int64): tuple[nid: string, events: seq[Event]] =
  ## A note of `clip` in `author`'s name at `ts`, as two unsigned parts and its note id. The
  ## author signs and publishes each (authorship.publishAuthored). Raises ValueError for a
  ## clip no member could read (voice_clip.encodeRecord) or an author that is not an identity.
  voicePartEvents(author, encodeRecord(clip), ts, clip.durationMs)

# ── the fold (§6) ────────────────────────────────────────────────────────────────

type
  Header = object
    ## What the header pass reads off one part's value (rule 2's value half), never its half
    ## of the clip: a pure function of the value, so of the event id, which is what lets a
    ## memo keep it.
    ok: bool                    ## the value is a part's: the six fields, each of its shape
    ts: int64
    durMs: int
    digest: string
  Part = object
    id: EventId
    at: int                     ## its event's index in the pass's `events`
    ts: int64
    durMs: int
    digest: string
    half: string                ## the half as canonical base64, when this pass parsed the value
    fresh: bool                 ## whether `half` holds it; else it is read back from the event
  Group = object
    nid, author: string
    have: array[VoiceParts, bool]
    part: array[VoiceParts, Part]
  Pass = object
    ## One header pass: the voice events in canonical order, and each (nid, author)'s
    ## standing parts, which index into them.
    events: seq[Event]
    groups: OrderedTable[(string, string), Group]
  VoiceMemo* = ref object
    ## What the hosted layer keeps per room (§6) so a read neither parses a part's value
    ## again nor decodes and checks a clip again: each part's header fields by event id, and
    ## the verdict on each note of two parts, keyed by the two standing parts' ids. An id is
    ## a content address, so both are pure functions of their keys, and a part that comes to
    ## stand in another's place makes another key. It holds no half of a clip: a verdict or
    ## a decode reads the half back from its event, once per pair judged and once per play.
    ## It grows by a part's id and four fields per part the room's view holds, and one
    ## verdict (about 140 B) per pair of parts that ever stood, against their 90 KB frames in
    ## the log; the log is append-only, so it is bounded by the room's log, and the room's
    ## memo goes when the member leaves it (voice_live.forgetRoom).
    verdicts: Table[string, VoiceState]
    headers: Table[EventId, Header]
    hits: int

proc newVoiceMemo*(): VoiceMemo = VoiceMemo()
proc len*(m: VoiceMemo): int = m.verdicts.len
proc hits*(m: VoiceMemo): int =
  ## How many verdicts the memo has served.
  m.hits
proc headers*(m: VoiceMemo): int =
  ## How many parts' headers the memo holds.
  m.headers.len

var valuesParsed {.threadvar.}: int
var halvesRead {.threadvar.}: int
proc voiceParses*(): int =
  ## How many voice/ values this file has parsed on this thread, memo or none: the header
  ## pass's, and `voiceContentOf`'s for an entry whose header the memo does not hold as a
  ## part's. A counting seam for tests, as VoiceMemo.hits is (voice_test §16, §17,
  ## voice_live_test §27, §28).
  valuesParsed
proc voiceHalfReads*(): int =
  ## How many halves a verdict or a decode has read back from their events on this thread,
  ## since the memo keeps no half: the other counting seam.
  halvesRead

proc voicePartKey(key: string): tuple[ok: bool, nid, author: string, i: int] =
  ## Rule 2's key half: exactly voice/<nid>/<author>/<i>/2, a 32-hex nid and a 128-hex
  ## author, both lowercase (as voiceEvents writes them), i "0" or "1". The value's half is
  ## parseValue's; the room's other folds ask `voiceStanding`, which applies both and rules
  ## 3 and 4.
  let p = key.split('/')
  if p.len != 5 or p[0] != "voice" or p[4] != $VoiceParts: return
  if not (isLowerHex(p[1], 32) and isLowerHex(p[2], 128)): return
  let i = (if p[3] == "0": 0 elif p[3] == "1": 1 else: -1)
  if i < 0: return
  (true, p[1], p[2], i)

const Sextets = block:   # each standard base64 character's value, -1 for every other character
  var t: array[char, int8]
  for c in char.low .. char.high:
    t[c] = (case c
            of 'A' .. 'Z': int8(ord(c) - ord('A'))
            of 'a' .. 'z': int8(ord(c) - ord('a') + 26)
            of '0' .. '9': int8(ord(c) - ord('0') + 52)
            of '+': 62'i8
            of '/': 63'i8
            else: -1'i8)
  t

proc isCanonicalBase64(s: string): bool =
  ## Whether `s` is the one spelling `encode` gives some bytes, decided without decoding: a
  ## length that is a multiple of 4, the standard alphabet only, `=` only as the last one or
  ## two characters, and the bits a padded last group leaves over all zero. std/base64's
  ## `decode` (Nim 2.2.4) skips whitespace inside its loop and then reads past the end of
  ## the string, an IndexDefect that no `except` catches, so nothing that fails this reaches
  ## it.
  if s.len mod 4 != 0: return false
  let pad = (if s.len == 0 or s[^1] != '=': 0 elif s[^2] != '=': 1 else: 2)
  for k in 0 ..< s.len - pad:
    if Sextets[s[k]] < 0: return false
  if pad > 0:
    # the last data character carries 2 (one `=`) or 4 (two) bits beyond the bytes
    let spare = (if pad == 1: 0b11 else: 0b1111)
    if (int(Sextets[s[s.len - pad - 1]]) and spare) != 0: return false
  true

proc parseValue(e: Event): tuple[h: Header, half: string] =
  ## The header pass, for one part's value: a JSON object of the six fields (authorSig
  ## optional here, the room's view having verified it), v this version, ts an integer,
  ## durMs an integer no clip exceeds (0..VoiceMaxMs), the digest 64 lowercase hex, the half
  ## canonical base64. Anything else is not a part. Decodes nothing.
  try:
    let j = parseJson(e.value)
    if j.kind != JObject: return
    for k, _ in j:
      if k notin PartFields: return
    let v = j{"v"}
    let ts = j{"ts"}
    let dur = j{"durMs"}
    let dg = j{"digest"}
    let pt = j{"part"}
    if v == nil or v.kind != JInt or v.getBiggestInt() != VoiceEventVersion: return
    if ts == nil or ts.kind != JInt: return
    if dur == nil or dur.kind != JInt or dur.getBiggestInt() notin 0'i64 .. int64(VoiceMaxMs): return
    if dg == nil or dg.kind != JString or not isLowerHex(dg.getStr(), 64): return
    if pt == nil or pt.kind != JString or not isCanonicalBase64(pt.getStr()): return
    (Header(ok: true, ts: ts.getBiggestInt(), durMs: int(dur.getBiggestInt()), digest: dg.getStr()),
     pt.getStr())
  except CatchableError:
    (Header(), "")

proc gather(events: seq[Event], memo: VoiceMemo): Pass =
  ## Each (nid, author)'s standing parts. Rule 3: in canonical order, the first well-formed
  ## copy of each part stands, and an equivocating later copy is ignored (as readBlob,
  ## xmr_msig_spend.nim), so every member keeps the same one whatever arrived first. A part
  ## whose header the memo holds is not parsed again; one this pass parses keeps its half
  ## for the pass alone, and the memo takes its header only.
  var voice: seq[Event]
  for e in events:
    if e.key.startsWith("voice/"): voice.add e
  result.events = canonicalOrder(voice)
  for at, e in result.events:
    let k = voicePartKey(e.key)
    if not k.ok: continue
    let g = (k.nid, k.author)
    if g in result.groups and result.groups[g].have[k.i]: continue
    let id = eventId(e)
    var h: Header
    var half = ""
    var fresh = false
    if memo != nil and id in memo.headers: h = memo.headers[id]
    else:
      (h, half) = parseValue(e)
      inc valuesParsed
      fresh = true
      if memo != nil: memo.headers[id] = h
    if not h.ok: continue
    if g notin result.groups: result.groups[g] = Group(nid: k.nid, author: k.author)
    result.groups[g].have[k.i] = true
    result.groups[g].part[k.i] = Part(id: id, at: at, ts: h.ts, durMs: h.durMs, digest: h.digest,
                                      half: half, fresh: fresh)

proc header(g: Group): tuple[kept: bool, note: VoiceNote] =
  ## Rule 4 for one (nid, author): the note id must derive from the author and a part's own
  ## (digest, ts), else nothing here is a note (squatting); the note is read off that part.
  ## Its state is arriving here; the verdict pass judges a note of two parts.
  for i in 0 ..< VoiceParts:
    if g.have[i] and noteIdOf(g.author, g.part[i].digest, g.part[i].ts) == g.nid:
      let p = g.part[i]
      result = (true, VoiceNote(nid: g.nid, author: g.author, ts: p.ts, durMs: p.durMs,
                                state: vsArriving))
      for k in 0 ..< VoiceParts:
        if g.have[k]: result.note.parts[k] = g.part[k].id
      return

type VoicePartOf* = tuple[nid, author: string, i: int]
  ## A standing part: its note's id, the author its key names, and which half it is.

proc voiceStanding*(events: seq[Event], memo: VoiceMemo = nil): Table[EventId, VoicePartOf] =
  ## Every standing part of a note the fold keeps, by event id: exactly the ids reduceVoice's
  ## notes name in `parts`, whatever each note's state (complete, arriving or broken). The
  ## header pass alone decides it (rules 2 to 4), so it decodes no clip and costs what
  ## threadLastTs does. An entry under voice/ that is not here is no note's part: a key or a
  ## value of the wrong shape, an equivocating later copy, or a squatted note id. This is
  ## what the room's other folds (the flow, provenance and so the room map) take a part to
  ## be, so all of them agree with the fold, and each passes its caller's memo on. Pass the
  ## room's authentic view.
  for _, g in gather(events, memo).groups:
    if not header(g).kept: continue
    for i in 0 ..< VoiceParts:
      if g.have[i]: result[g.part[i].id] = (g.nid, g.author, i)

proc voiceContentOf*(value: string, id: EventId, memo: VoiceMemo = nil): JsonNode =
  ## What the room map shows of an entry under voice/ (§10), a part or not: `v`, `ts` and
  ## `durMs` where each is an integer, and `digest` where it is 64 lowercase hex, never
  ## `part`, the half of the clip, nor any other field, so no audio rides the map whatever an
  ## entry holds. `id` is the entry's event id. For a part whose header the memo holds, the
  ## header gives the four, since a part's value has exactly those beside its half and
  ## signature (rule 2), so the value is not parsed again; any other entry is parsed, and
  ## counted in voiceParses.
  if memo != nil and id in memo.headers and memo.headers[id].ok:
    let h = memo.headers[id]
    return %*{"v": VoiceEventVersion, "ts": h.ts, "durMs": h.durMs, "digest": h.digest}
  result = newJObject()
  inc valuesParsed
  try:
    let j = parseJson(value)
    if j.kind != JObject: return
    for k in ["v", "ts", "durMs"]:
      if j{k} != nil and j[k].kind == JInt: result[k] = j[k]
    let dg = j{"digest"}
    if dg != nil and dg.kind == JString and dg.getStr().len == 64 and
       dg.getStr().allCharsInSet({'0' .. '9', 'a' .. 'f'}):
      result["digest"] = dg
  except CatchableError: discard

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc halfOf(p: Pass, part: Part): string =
  ## A standing part's half: the pass's own, else read back from its event, whose id names
  ## the value the header was read from.
  if part.fresh: return part.half
  inc halvesRead
  parseValue(p.events[part.at]).half

proc verdict(p: Pass, g: Group): tuple[state: VoiceState, record: seq[byte]] =
  ## Rules 5 and 6 for a note's two parts: they agree on ts, length and digest, and the
  ## record they make matches the digest, passes the structural checks (§3.2) and is the
  ## length it claims. The header pass let through canonical base64 only, which `decode`
  ## reads whole.
  let (a, b) = (g.part[0], g.part[1])
  if a.ts != b.ts or a.durMs != b.durMs or a.digest != b.digest: return (vsBroken, @[])
  let record = bytesOf(decode(p.halfOf(a))) & bytesOf(decode(p.halfOf(b)))
  if hexOf(clipDigest(record)) != a.digest: return (vsBroken, @[])
  let (ok, clip, _) = decodeRecord(record)
  if not ok or clip.durationMs != a.durMs: return (vsBroken, @[])
  (vsComplete, record)

proc judged(p: Pass, g: Group, memo: VoiceMemo, wantRecord = false):
    tuple[kept: bool, note: VoiceNote, record: seq[byte]] =
  ## A kept note with its state: arriving on one part, else the verdict on its two, the
  ## memo's when it holds one for these parts' ids. With `wantRecord`, a complete note's
  ## clip record too: the verdict's, or, on the memo's verdict, the two halves read back.
  let h = header(g)
  result.kept = h.kept
  result.note = h.note
  if not result.kept or not (g.have[0] and g.have[1]): return
  let key = g.part[0].id & g.part[1].id
  if memo != nil and key in memo.verdicts:
    inc memo.hits
    result.note.state = memo.verdicts[key]
    if wantRecord and result.note.state == vsComplete:
      result.record = bytesOf(decode(p.halfOf(g.part[0]))) & bytesOf(decode(p.halfOf(g.part[1])))
    return
  let v = verdict(p, g)
  result.note.state = v.state
  if wantRecord: result.record = v.record
  if memo != nil: memo.verdicts[key] = v.state

proc byTsNid(x, y: VoiceNote): int =
  if x.ts != y.ts: cmp(x.ts, y.ts) else: cmp(x.nid, y.nid)

proc reduceVoice*(events: seq[Event], memo: VoiceMemo = nil): seq[VoiceNote] =
  ## The room's voice notes, each complete, arriving or broken, ordered by (ts, nid). A pure
  ## function of the event set (invariant 4), with a memo or without. Pass the room's
  ## authentic view (`roomEvents`).
  let p = gather(events, memo)
  for _, g in p.groups:
    let j = judged(p, g, memo)
    if j.kept: result.add j.note
  result.sort(byTsNid)

proc voiceNoteOf*(events: seq[Event], nid: string, memo: VoiceMemo = nil):
    tuple[found: bool, note: VoiceNote, record: seq[byte]] =
  ## The note `nid` as reduceVoice reads it, and for a complete one its clip record, exactly
  ## the bytes its digest names, from one header pass and the memo's verdict (what voice_play
  ## needs); not found for a note not in the room. Only this note is judged.
  let p = gather(events, memo)
  var best: Group
  var bestNote: VoiceNote
  for _, g in p.groups:
    if g.nid != nid: continue
    let h = header(g)
    # reduceVoice's last of the notes with this nid, as play read them: one in practice,
    # since the nid commits to its author
    if h.kept and (not result.found or byTsNid(h.note, bestNote) >= 0):
      best = g
      bestNote = h.note
      result.found = true
  if not result.found: return
  let j = judged(p, best, memo, wantRecord = true)
  result.note = j.note
  if j.note.state == vsComplete: result.record = j.record

proc voiceRecordOf*(events: seq[Event], nid: string, memo: VoiceMemo = nil):
    tuple[ok: bool, record: seq[byte]] =
  ## The clip record of the complete note `nid`, exactly the bytes its digest names, as the
  ## fold checked them; not ok for a note that is not complete, or not in the room.
  let n = voiceNoteOf(events, nid, memo)
  if n.found and n.note.state == vsComplete: (true, n.record) else: (false, @[])

# ── thread rows (§7) ─────────────────────────────────────────────────────────────

proc threadRows*(events: seq[Event], memo: VoiceMemo = nil): seq[ThreadRow] =
  ## The room's thread: every message (`reduceMessages`, unchanged) and one row per note
  ## (`reduceVoice`), ordered by (ts, id); a message sorts before a note of the same (ts,
  ## id). A note's row names the fold's author, has an empty body, and carries the note in
  ## `note` alone, which no message can set. Pass the room's authentic view.
  for m in reduceMessages(events):
    result.add ThreadRow(id: m.id, author: m.author, ts: m.ts, body: m.body)
  for n in reduceVoice(events, memo):
    result.add ThreadRow(id: n.nid, author: n.author, ts: n.ts, body: "", isVoice: true, note: n)
  result.sort(proc(x, y: ThreadRow): int =
    if x.ts != y.ts: cmp(x.ts, y.ts)
    elif x.id != y.id: cmp(x.id, y.id)
    else: cmp(ord(x.isVoice), ord(y.isVoice)))

proc threadLastTs*(events: seq[Event], memo: VoiceMemo = nil): int64 =
  ## The newest row's ts, a note's included (0 when the thread is empty): what moves a room
  ## up the list (coordinate_conversations' lastTs). A note's row is there whatever its
  ## state, so this needs the header pass alone and judges no clip; with the room's memo it
  ## parses no part it has read before.
  var seen = false
  for m in reduceMessages(events):
    if not seen or m.ts > result: result = m.ts
    seen = true
  for _, g in gather(events, memo).groups:
    let h = header(g)
    if h.kept and (not seen or h.note.ts > result): (result = h.note.ts; seen = true)
  if not seen: result = 0

proc voiceJson*(n: VoiceNote): JsonNode =
  ## A voice row's `voice` field: the note's metadata, never its audio (§7).
  %*{"v": VoiceEventVersion, "note": n.nid, "durationMs": n.durMs, "state": $n.state}

proc rowJson*(r: ThreadRow): JsonNode =
  ## A row as coordinate_messages serves it, before the hosted layer adds `alias` and
  ## `self`: {id, author, ts, body}, and `voice` on a note's row only.
  result = %*{"id": r.id, "author": r.author, "ts": r.ts, "body": r.body}
  if r.isVoice: result["voice"] = voiceJson(r.note)
