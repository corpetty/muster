## Settlement in parts + effect-named parties (exo-a90.2, docs/design/split-the-bill.md
## §4.2–§4.3): the driver-generic seams a split rides on, exercised with a test driver
## that is NOT the split — so what is proven here is the core's generic rule:
##   * describeFor(effect): the threshold comes from the parties the effect names, and a
##     name outside them never counts;
##   * settlementParts / partAuthor: each part is settled by its own party and confirmed
##     by the counterparty; any settled → submitted, any confirmed → settling, all
##     confirmed → final; a confirmation alone (received outside muster) settles a part;
##   * a report by anyone but the allowed author never counts, a report before the intent
##     is agreed never counts, and a bare submit / final never moves a parts intent;
##   * the view names every part's state; activity and provenance tell the same story;
##   * the whole thing is reduce(log): reorder + duplication → identical state (inv 4).
## Pure Nim, no crypto: the test driver's "signature" is the contributor's name.

import std/[json, strutils, random, algorithm, sequtils]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/manifest   # fieldText
import ../src/log/log
import ../src/coordination/intents

# ── a test driver whose parties are named in the effect ──────────────────────────
# effect: a statement whose text is "parts=<a>,<b>,…;to=<counterparty>". A contribution
# is the contributor's name as bytes; it counts iff that name is one of the parts. The
# part "<p>" is settled by the author "<p>" and confirmed by the counterparty.
type PartsDriver = ref object of Driver
  pending: seq[byte]

proc spec(e: Effect): tuple[parts: seq[string], to: string] =
  for piece in fieldText(e, "text").split(';'):
    let kv = piece.split('=')
    if kv.len != 2: continue
    if kv[0] == "parts": result.parts = kv[1].split(',').filterIt(it.len > 0)
    elif kv[0] == "to": result.to = kv[1]

proc specOfBytes(m: seq[byte]): tuple[parts: seq[string], to: string] =
  # the base canonicalize is [domain, schemaId, {fields}]: read the text back
  try:
    let v = decode(m)
    for (k, x) in v.arr[2].pairs:
      if k.t == "text":
        return spec(Effect(fields: @[("text", x)]))
  except CatchableError: discard

method describe(d: PartsDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "muster.test.parts.v1",
                   finality: finExternal, threshold: 1)
method describeFor(d: PartsDriver, e: Effect): DriverDescriptor =
  result = d.describe()
  result.threshold = max(1, spec(e).parts.len)
method expectMaterialization(d: PartsDriver, m: Materialization) = d.pending = m.bytes
proc nameOf(c: Contribution): string = (for b in c.bytes: result.add char(b))
method verifyContribution(d: PartsDriver, c: Contribution, round: int): bool =
  nameOf(c) in specOfBytes(d.pending).parts
method identifyContributor(d: PartsDriver, m: Materialization, c: Contribution): string =
  (if nameOf(c) in specOfBytes(m.bytes).parts: nameOf(c) else: "")
method settlementParts(d: PartsDriver, e: Effect): seq[string] = spec(e).parts
method partAuthor(d: PartsDriver, e: Effect, part, step: string): string =
  let s = spec(e)
  if part notin s.parts: return ""
  case step
  of "settled": part
  of "confirmed": s.to
  else: ""

let drv = PartsDriver()
let dfor: DriverFor = proc(kind: string): Driver = drv

let effectJson = $(%*{"effect": "statement", "text": "parts=alice,bob;to=carol"})
let id = intentIdFor(effectJson, "parts")
proc hexName(s: string): string =
  const d = "0123456789abcdef"
  for c in s: (result.add d[int(byte(c) shr 4)]; result.add d[int(byte(c) and 0x0F)])
proc agree(who: string): Event = contributeEvent(id, who, hexName(who))

let base = @[policyDeclEvent(id, "parts"), proposeEvent(id, effectJson)]
proc st(evs: seq[Event]): string = intentState(evs, dfor, id)
proc viewOf(evs: seq[Event]): IntentView =
  for v in reduceIntentViews(evs, dfor):
    if v.id == id: return v
  doAssert false, "intent not folded"

# ── 1. the threshold comes from the effect; a name outside it never counts ────────
block:
  doAssert drv.describe().threshold == 1
  doAssert describeFor(drv, effectFromJson(effectJson)).threshold == 2
  doAssert st(base & @[agree("alice")]) == "collecting", "one of two named parties -> collecting"
  doAssert st(base & @[agree("alice"), agree("mallory")]) == "collecting",
           "a name the effect does not carry never counts"
  doAssert st(base & @[agree("alice"), agree("bob")]) == "executable",
           "every named party agreed -> executable (threshold 2, not describe()'s 1)"
  let v = viewOf(base & @[agree("alice")])
  doAssert v.threshold == 2 and v.approvals == 1, "the view carries the per-proposal threshold"
  echo "1. describeFor: threshold from the effect's parties; outsiders never count OK"

let agreed = base & @[agree("alice"), agree("bob")]

# ── 2. parts drive the lifecycle: settled → submitted → settling → final ──────────
block:
  let s1 = agreed & @[partEvent(id, "alice", "settled", "alice", "0xaa")]
  doAssert st(s1) == "submitted", "a part settled -> submitted: " & st(s1)
  let s2 = s1 & @[partEvent(id, "alice", "confirmed", "carol", "0xaa")]
  doAssert st(s2) == "settling", "a part confirmed -> settling: " & st(s2)
  let s3 = s2 & @[partEvent(id, "bob", "settled", "bob", "0xbb")]
  doAssert st(s3) == "settling", "every part must be CONFIRMED, not just settled"
  let s4 = s3 & @[partEvent(id, "bob", "confirmed", "carol", "0xbb")]
  doAssert st(s4) == "final", "every part confirmed -> final: " & st(s4)
  echo "2. settled -> submitted, confirmed -> settling, all confirmed -> final OK"

# ── 3. a confirmation alone settles a part (received outside muster) ─────────────
block:
  let evs = agreed & @[partEvent(id, "alice", "confirmed", "carol", ""),
                       partEvent(id, "bob", "confirmed", "carol", "")]
  doAssert st(evs) == "final", "the counterparty's word settles a part paid in cash"
  let v = viewOf(evs)
  for p in v.parts:
    doAssert p.settled and p.confirmed and p.tx == "", "outside muster: no chain reference"
  echo "3. confirmed without a report = received outside muster OK"

# ── 4. only the allowed author counts ─────────────────────────────────────────────
block:
  let forged = agreed & @[partEvent(id, "alice", "settled", "bob", "0xaa"),       # bob claims alice paid
                          partEvent(id, "alice", "confirmed", "alice", "0xaa"),   # alice confirms herself
                          partEvent(id, "mallory", "settled", "mallory", "0xcc")] # not a part
  doAssert st(forged) == "executable", "no report by a disallowed author moves the lifecycle: " & st(forged)
  let v = viewOf(forged)
  doAssert v.parts.len == 2 and v.parts.allIt(not it.settled and not it.confirmed)
  echo "4. a report by anyone but the allowed author never counts OK"

# ── 5. before agreement, and bare submit/final, never move a parts intent ─────────
block:
  let early = base & @[agree("alice"), partEvent(id, "alice", "settled", "alice", "0xaa"),
                       partEvent(id, "alice", "confirmed", "carol", "0xaa")]
  doAssert st(early) == "collecting", "a part report before the intent is agreed never counts"
  let bare = agreed & @[submitEvent(id, chainRef = "0xzz"), finalEvent(id, chainRef = "0xzz")]
  doAssert st(bare) == "executable", "a bare submit/final never finalizes a parts intent: " & st(bare)
  echo "5. no report counts before agreement; a bare submit/final is inert OK"

# ── 6. the view, the activity feed and provenance name each part ─────────────────
block:
  let evs = agreed & @[partEvent(id, "alice", "settled", "alice", "0xaa"),
                       partEvent(id, "alice", "confirmed", "carol", "0xaa")]
  let v = viewOf(evs)
  doAssert v.parts.mapIt(it.part) == @["alice", "bob"], "parts in the driver's order"
  doAssert v.parts[0].settled and v.parts[0].confirmed and v.parts[0].tx == "0xaa"
  doAssert v.parts[0].settledBy == "alice" and v.parts[0].confirmedBy == "carol"
  doAssert not v.parts[1].settled and not v.parts[1].confirmed
  var paid, confirmed = 0
  for a in reduceActivity(evs, dfor):
    if a.intentId != id: continue
    if a.kind == "part-settled": (inc paid; doAssert a.account == "alice")
    if a.kind == "part-confirmed": (inc confirmed; doAssert a.account == "carol")
  doAssert paid == 1 and confirmed == 1, "one activity line per counted report"
  var kinds: seq[string]
  for p in logProvenance(evs, dfor):
    if p.intentId == id and p.kind.startsWith("part-"): kinds.add p.kind & "/" & $p.cls
  doAssert kinds == @["part-settled/" & $icPeerMessage, "part-confirmed/" & $icExternalRead] or
           kinds == @["part-confirmed/" & $icExternalRead, "part-settled/" & $icPeerMessage], $kinds
  echo "6. view + activity + provenance name each part's state OK"

# ── 6b. every activity line with people in it names them as data (exo-221) ───────
# The fold keeps who acted (account) and whose part it was (subject), so the hosted layer
# can say "you" / "Bob" there exactly as the card does; activityTitle re-renders a line
# with names, and never leaves a raw id when a name is known.
block:
  let evs = agreed & @[partEvent(id, "alice", "settled", "alice", "0xaa"),
                       partEvent(id, "alice", "confirmed", "carol", "0xaa")]
  let label = proc(who: string): string =
    (if who == "alice": "you" elif who == "carol": "Carol" elif who == "bob": "Bob" else: who)
  var titles: seq[string]
  for a in reduceActivity(evs, dfor):
    if a.intentId != id: continue
    case a.kind
    of "part-settled": doAssert a.account == "alice" and a.subject == "alice", $a
    of "part-confirmed": doAssert a.account == "carol" and a.subject == "alice", $a
    else: discard
    titles.add activityTitle(a, label)
  doAssert "Approved by you" in titles and "Approved by Bob" in titles, $titles
  doAssert "You settled your part" in titles, $titles
  doAssert "Carol confirmed your part" in titles, $titles
  let other = agreed & @[partEvent(id, "bob", "settled", "bob", "0xbb"),
                         partEvent(id, "bob", "confirmed", "carol", "0xbb")]
  var t2: seq[string]
  for a in reduceActivity(other, dfor):
    if a.intentId == id and a.kind.startsWith("part-"): t2.add activityTitle(a, label)
  doAssert t2 == @["Bob settled their part", "Carol confirmed Bob's part"], $t2
  echo "6b. activity lines carry who acted and whose part; titled with the card's names OK"

# ── 7. reduce(log): reorder + duplication → identical state and view (inv 4) ──────
block:
  let full = agreed & @[partEvent(id, "alice", "settled", "alice", "0xaa"),
                        partEvent(id, "alice", "settled", "bob", "0xff"),        # forged
                        partEvent(id, "bob", "confirmed", "carol", ""),
                        partEvent(id, "alice", "confirmed", "carol", "0xaa"),
                        submitEvent(id), agree("mallory")]
  let want = viewOf(full)
  doAssert want.state == "final"
  var rng = initRand(0xa90)
  for trial in 0 ..< 200:
    var evs = full
    for _ in 0 ..< rng.rand(3): evs.add evs[rng.rand(evs.high)]    # duplicates
    rng.shuffle(evs)
    let got = viewOf(evs)
    doAssert got.state == want.state and got.parts == want.parts and got.approvals == want.approvals,
             "trial " & $trial & ": " & got.state
  echo "7. 200 reorder+duplicate trials converge on the same parts and state (inv 4) OK"

# ── 8. a driver without parts is untouched: submit / final still settle it ───────
block:
  let plain: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 1, verifyResult = true)
  let ej = """{"to":"0xabc","value":1}"""
  let pid = intentIdFor(ej)
  let evs = @[proposeEvent(pid, ej), contributeEvent(pid, "x", "01"), submitEvent(pid), finalEvent(pid)]
  doAssert intentState(evs, plain, pid) == "final", "single-submitter families settle as before"
  var v: IntentView
  for x in reduceIntentViews(evs, plain):
    if x.id == pid: v = x
  doAssert v.parts.len == 0, "no parts declared -> none shown"
  echo "8. a family without parts settles exactly as before OK"

echo "parts_fold_test: all OK"
