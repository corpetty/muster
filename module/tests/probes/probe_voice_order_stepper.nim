## voice-notes.md §6 rules 3 and 6, invariant 4, held as an oracle for a future derived-exo
## spec (S5): every member folds a note's parts to the same note whatever their order or
## duplication, and of two copies of a part the first in canonical order stands, so a part
## the author equivocated on reads the same everywhere.
##
## STEPPER: over four events of Alice's note — her part 0 (p0), her part 1 (p1), a second
## copy of p0 (the same event, carrying an `after` nobody signed), and an equivocating p1'
## (Alice's own second part 1: the same ts, length and digest, other bytes, chosen so that
## its event id sorts before p1's) — state = which event is delivered first (four states,
## chained head -> head+1). Each state folds every order of the other three, as-is AND with
## every event delivered twice, through the real fold (reduceVoice and threadRows), and
## requires each to equal the fold of the four in the identity order. Every state also folds
## every SUBSET of the four (16) through the hosted read path (authenticEvents, then
## reduceVoice) and requires it to match the rule stated alone:
##   * neither part 0 (p0 or its copy) nor part 1 (p1 or p1'): no note;
##   * exactly one of them: Alice's note, arriving;
##   * both: the part 1 that stands is, of p1 and p1' present, the one with the smaller event
##     id (canonical order: neither names a parent); the note is complete iff that is p1, and
##     broken otherwise (p1' makes a record that misses the digest).
## Every note found names the standing parts' event ids.
## Run by hand (no argv), it checks every order and subset with doAssert.

import std/algorithm
import ./voice_room
import ./oracle_emit

const Ts = 1_792_000_300'i64
let n = note(aliceKs, 3_000, Ts, 7)
let p0 = n.parts[0]
let p1 = n.parts[1]
let p0copy = block:
  var e = p0
  e.after = @[eventId(p1)]
  e

proc equivocation(): Event =
  ## Alice's own second part 1 for the same note, other bytes, sorting before p1.
  for salt in 8'u8 .. 250'u8:
    let other = note(aliceKs, 3_000, Ts, salt)
    var j = parseJson(stripped(p1).value)
    j["part"] = parseJson(other.parts[1].value)["part"]
    let e = signAuthored(aliceKs, Room, Event(key: p1.key, value: $j))
    if eventId(e) < eventId(p1): return e
  raise newException(ValueError, "no equivocating copy sorts first")

let p1x = equivocation()
let events = @[p0, p1, p0copy, p1x]

proc ruleOf(subset: set[0 .. 3]): seq[VoiceNote] =
  ## The rule, computed without reduceVoice.
  let has0 = 0 in subset or 2 in subset
  var standing = ""
  for i in [1, 3]:
    if i in subset and (standing.len == 0 or eventId(events[i]) < standing): standing = eventId(events[i])
  if not has0 and standing.len == 0: return
  var v = VoiceNote(nid: n.nid, author: alice, ts: Ts, durMs: 3_000)
  if has0: v.parts[0] = eventId(p0)
  v.parts[1] = standing
  v.state = (if not has0 or standing.len == 0: vsArriving
             elif standing == eventId(p1): vsComplete
             else: vsBroken)
  @[v]

let reference = reduceVoice(events)
let referenceRows = threadRows(events)
doAssert reference == ruleOf({0 .. 3}), "the reference fold is the rule's"
doAssert reference[0].state == vsBroken, "p1' sorts first, so it stands"

proc subsetsCorrect(): bool =
  for mask in 0 ..< 16:
    var evs: seq[Event]
    var has: set[0 .. 3]
    for i in 0 ..< 4:
      if (mask and (1 shl i)) != 0: (evs.add events[i]; has.incl i)
    if view(evs) != ruleOf(has): return false
  true

proc correct(perm: seq[int]): bool =
  var order: seq[Event]
  for e in perm: order.add events[e]
  reduceVoice(order) == reference and reduceVoice(order & order) == reference and
    threadRows(order) == referenceRows and threadRows(order & order) == referenceRows

proc headCorrect(h: int): bool =
  if not subsetsCorrect(): return false
  var rest: seq[int]
  for i in 0 ..< events.len:
    if i != h: rest.add i
  while true:
    if not correct(@[h] & rest): return false
    if not rest.nextPermutation(): break
  true

proc state(h: int): JsonNode = %*{"case": h, "decision_correct": headCorrect(h)}

let arg = oracleStateArg()
if arg == nil:
  doAssert subsetsCorrect(), "a subset folds to a note other than the rule's"
  var p = @[0, 1, 2, 3]
  var count = 0
  while true:
    doAssert correct(p), "order " & permString(p) & " folds to a different note"
    inc count
    if not p.nextPermutation(): break
  doAssert count == 24
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod events.len)])
