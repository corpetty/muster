## voice-notes.md §3.3, §6 rules 1 and 4, §7, invariant 9, held as an oracle for a future
## derived-exo spec (S5): a voice note is credited to a member only by that member's own
## signed parts, for this room, under the note id their own clip derives; and only the fold
## makes a voice row, so a message cannot pose as another member's note.
##
## STEPPER: one state per case, chained case -> case+1. A case is one part of Alice's note
## (part 0 or part 1), beside her other part, genuine, in one of six forms:
##   genuine   — signed by Alice, for this room
##   forged    — Alice's part as she sent it, signed by Mallory (the key still names Alice)
##   unsigned  — the signature removed
##   otherroom — signed by Alice, for another room
##   edited    — genuine, then its clip bytes swapped for another clip's
##   squatted  — Alice's part, keyed under Alice's note id with Mallory's author segment and
##               signed by Mallory: Mallory claiming Alice's note as hers
## (twelve), plus two forged-row cases: Mallory's own signed `message/`s whose body claims
## kind `voice-note` with Alice's note id (one also carries a `voice` field in its value),
## with Alice's complete note in the log, and without it; plus ten malformed cases, part 0
## or part 1 signed by Alice with its half replaced by a string with whitespace in it that
## std/base64's decode (Nim 2.2.4) reads past the end of (the last one 12 characters long,
## so a length check alone does not stop it). Each case reads the room the way
## the hosted module does (authenticEvents, then reduceVoice and threadRows). Correct iff:
##   * genuine: one note, Alice's, complete, its record Alice's; one voice row, credited to
##     Alice;
##   * every other part form: one note, Alice's, arriving on her other part alone; nothing is
##     complete, and no note and no voice row is credited to Mallory;
##   * a forged row: the voice rows are exactly the fold's notes (Alice's when her note is
##     present, none otherwise), each credited to Alice; each of Mallory's messages is a row of
##     hers with no `voice` field, its body the JSON she posted;
##   * a malformed part: authentic, yet no part, so one note, Alice's, arriving on her other
##     part alone, with one voice row and the newest row's ts hers; and nothing raises (a
##     Defect aborts the probe).
## Run by hand (no argv), it checks every case with doAssert.

import ./voice_room
import ./oracle_emit

const Forms = ["genuine", "forged", "unsigned", "otherroom", "edited", "squatted"]
const Malformed = ["    AB", "AAAA    A", "  ABC", "AAAA\n\n\n\nAB", "AAAA     AAA"]
const firstMalformed = Forms.len * 2 + 2
const caseCount = firstMalformed + Malformed.len * 2
const noteTs = 1_792_000_100'i64

let n = note(aliceKs, 3_000, noteTs, 1)
let other = note(aliceKs, 3_000, 1_792_000_101, 2)

proc partIn(form: string, i: int): Event =
  let genuine = n.parts[i]
  case form
  of "genuine": genuine
  of "forged": signedBy(malloryKs, genuine)
  of "unsigned": stripped(genuine)
  of "otherroom": signedBy(aliceKs, genuine, OtherRoom)
  of "edited": edited(genuine, "part", parseJson(other.parts[i].value)["part"])
  else:
    let k = "voice/" & n.nid & "/" & mallory & "/" & $i & "/" & $VoiceParts
    signAuthored(malloryKs, Room, rekeyed(stripped(genuine), k))

proc voiceRows(rs: seq[ThreadRow]): seq[ThreadRow] =
  for r in rs:
    if r.isVoice: result.add r

proc forgedRowCorrect(withNote: bool): bool =
  let body = $(%*{"kind": "voice-note", "v": 1, "note": n.nid, "durationMs": 3_000,
                  "state": "complete"})
  let (_, m1) = newMessageEvent(mallory, 1_792_000_200, body, 1)
  let (_, m2raw) = newMessageEvent(mallory, 1_792_000_201, body, 2)
  var j = parseJson(m2raw.value)
  j["voice"] = %*{"v": 1, "note": n.nid, "durationMs": 3_000, "state": "complete"}
  let m2 = Event(key: m2raw.key, value: $j)
  let msgs = @[signAuthored(malloryKs, Room, m1), signAuthored(malloryKs, Room, m2)]
  let evs = (if withNote: n.parts & msgs else: msgs)
  let notes = view(evs)
  let rs = rows(evs)
  let vr = voiceRows(rs)
  if vr.len != notes.len or vr.len != (if withNote: 1 else: 0): return false
  for r in vr:
    if r.author != alice or r.id != n.nid or r.note.nid != n.nid or r.body != "": return false
  var hers = 0
  for r in rs:
    if r.author != mallory: continue
    inc hers
    if r.isVoice or rowJson(r).hasKey("voice") or r.body != body: return false
  hers == 2

proc malformedCorrect(m, i: int): bool =
  ## Alice's own part i, its half `Malformed[m]`, signed by her, beside her genuine other part.
  let e = signedBy(aliceKs, edited(n.parts[i], "part", %Malformed[m]))
  let evs = @[n.parts[1 - i], e]
  let authentic = authenticEvents(evs, Room)
  if authentic.len != 2: return false                       # authentic, yet not a part
  let notes = view(evs)
  let vr = voiceRows(rows(evs))
  if notes.len != 1 or vr.len != 1 or vr[0].author != alice: return false
  let got = notes[0]
  got.nid == n.nid and got.author == alice and got.state == vsArriving and
    got.parts[i] == "" and got.parts[1 - i] == eventId(n.parts[1 - i]) and
    threadLastTs(authentic) == noteTs

proc correct(c: int): bool =
  if c >= firstMalformed:
    let k = c - firstMalformed
    return malformedCorrect(k div 2, k mod 2)
  if c >= Forms.len * 2: return forgedRowCorrect(c == Forms.len * 2)
  let form = Forms[c div 2]
  let i = c mod 2
  let evs = @[n.parts[1 - i], partIn(form, i)]
  let notes = view(evs)
  let vr = voiceRows(rows(evs))
  for x in notes:
    if x.author == mallory: return false
  for r in vr:
    if r.author == mallory: return false
  if notes.len != 1 or vr.len != 1: return false
  let got = notes[0]
  if got.nid != n.nid or got.author != alice or vr[0].author != alice: return false
  if form == "genuine":
    let (ok, record) = voiceRecordOf(authenticEvents(evs, Room), n.nid)
    return got.state == vsComplete and ok and record == n.record
  got.state == vsArriving and got.parts[1 - i] == eventId(n.parts[1 - i]) and got.parts[i] == ""

proc state(c: int): JsonNode = %*{"case": c, "decision_correct": correct(c)}

let arg = oracleStateArg()
if arg == nil:
  for c in 0 ..< caseCount:
    doAssert correct(c), "case " & $c & " (" &
      (if c < Forms.len * 2: Forms[c div 2] & ", part " & $(c mod 2)
       elif c < firstMalformed: "forged row"
       else: "malformed " & escapeJson(Malformed[(c - firstMalformed) div 2]) & ", part " & $((c - firstMalformed) mod 2)) & ")"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod caseCount)])
