## A room's charter (exo-267.1; docs/design/logos-world-plan.md Phase 1): a founding
## log entry, a per-action policy table, and the rule for changing rules — all a fold.
##
## A charter is a proposal under the `charter` kind. Its effect names the ELECTORATE that
## decides it and how many of them must agree, so whether a charter took force never
## depends on who joined the room afterwards. The fold then accepts:
##   * a founding charter (no prev) only when every member it names agreed to it;
##   * an amendment only when it names the charter in force as prev AND was decided
##     under that charter's own rule (its members, its amend k);
## and among agreed amendments of the same charter, one, the same on every member.
## Pure Nim, no host: Ed25519 room keys sign the materialization directly.

import std/[json, strutils, sequtils, random, algorithm]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/charter
import ../src/drivers/conformance
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/accounts
import ../src/coordination/room_charter
import ../src/coordination/effect_summary

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let alice = encFromSeed(seed(1))
let bob = encFromSeed(seed(2))
let carol = encFromSeed(seed(3))
let dave = encFromSeed(seed(4))          # in the room, never in the charter
proc idOf(k: EncKeys): string = hx(k.identity().toBytes())
proc edName(k: EncKeys): string = "ed:" & hx(k.identity().ed)
let members = @[idOf(alice), idOf(bob), idOf(carol)]

let driverFor: DriverFor = proc(kind: string): Driver =
  newCharterDriver(members & @[idOf(dave)])

proc propose(effectJson: string): (string, seq[Event]) =
  let id = intentIdFor(effectJson, CharterKind)
  (id, @[proposeEvent(id, effectJson), policyDeclEvent(id, CharterKind)])

proc sign(k: EncKeys, id, effectJson: string): Event =
  let m = canonicalize(driverFor(CharterKind), effectFromJson(effectJson))
  contributeEvent(id, edName(k), hx(edSign(k, m.bytes)))

let circle = circleTemplate(name = "Tuesday circle", purpose = "save together, pay out in turn",
                            members = members, amendK = 2,
                            account = "lez:local:" & repeat("ab", 32),
                            share = "100", asset = "LEZ", cadenceSec = 7 * 86_400)

# ── 1. the template is a charter body, and carries no type ────────────────────
block:
  let (ok, body, why) = parseCharterBody(circle)
  doAssert ok, why
  doAssert body.members == members and body.amendK == 2
  doAssert body.rules.anyIt(it[0] == "amend-charter"), "every charter has a rule for changing rules"
  doAssert body.schedule.order == members, "a circle pays out in turn"
  for key in circle.keys: doAssert key notin ["type", "orgType", "kind"], "no org type: " & key
  var typed = circle.copy()
  typed["type"] = %"circle"
  doAssert not parseCharterBody(typed)[0], "a body with an org type is refused (closed vocabulary)"
  var noAmend = circle.copy()
  noAmend["rules"].delete("amend-charter")
  doAssert not parseCharterBody(noAmend)[0], "a charter with no rule for changing rules is refused"
  echo "1. the circle is a charter template; no type field, an amend rule required OK"

# ── 2. founding: every member it names must agree ─────────────────────────────
let foundJson = foundingEffect(circle)
let (foundId, foundEvs) = propose(foundJson)
block:
  var evs = foundEvs & @[sign(alice, foundId, foundJson), sign(bob, foundId, foundJson)]
  doAssert not charterInForce(evs, driverFor).found, "two of three founders is not a founding"
  evs.add sign(dave, foundId, foundJson)
  doAssert not charterInForce(evs, driverFor).found, "a room member the charter does not name decides nothing"
  evs.add sign(carol, foundId, foundJson)
  let c = charterInForce(evs, driverFor)
  doAssert c.found and c.id == foundId and c.body.name == "Tuesday circle", $c.found
  doAssert c.history == @[foundId]
  echo "2. founded only when all three named members agreed; dave's signature counts for nothing OK"

let founded = foundEvs & @[sign(alice, foundId, foundJson), sign(bob, foundId, foundJson),
                           sign(carol, foundId, foundJson)]

# ── 3. an amendment under the charter's own rule ──────────────────────────────
var renamed = circle.copy()
renamed["name"] = %"Tuesday savings circle"
let amendJson = amendmentEffect(charterInForce(founded, driverFor), renamed)
let (amendId, amendEvs) = propose(amendJson)
block:
  var evs = founded & amendEvs & @[sign(carol, amendId, amendJson)]
  doAssert charterInForce(evs, driverFor).id == foundId, "one of the two the rule needs is not enough"
  evs.add sign(alice, amendId, amendJson)
  let c = charterInForce(evs, driverFor)
  doAssert c.id == amendId and c.body.name == "Tuesday savings circle"
  doAssert c.history == @[foundId, amendId]
  # what the card counts against: the three it names, though two decide it
  doAssert driverFor(CharterKind).electorateFor(effectFromJson(amendJson)) == 3
  doAssert describeFor(driverFor(CharterKind), effectFromJson(amendJson)).threshold == 2
  # and the room's summary names it a charter, not a policy
  doAssert effectSummary(amendJson, proc(w: string): string = w).kind == "charter"
  doAssert effectSummary(foundJson, proc(w: string): string = w).text == "found the charter: “Tuesday circle”"
  echo "3. amended by two of three, the founding charter's own rule OK"

# ── 4. an amendment NOT under the rule never takes force ──────────────────────
block:
  # declares k = 1 where the charter in force says 2: agreed by its own count, out of rule
  var lax = parseJson(amendmentEffect(charterInForce(founded, driverFor), renamed))
  lax["k"] = %1
  lax["body"]["purpose"] = %"whatever one of us says"
  let laxJson = $lax
  let (laxId, laxEvs) = propose(laxJson)
  var evs = founded & laxEvs & @[sign(alice, laxId, laxJson)]
  doAssert intentState(evs, driverFor, laxId) == "executable", "it is agreed by its own declared count"
  let c = charterInForce(evs, driverFor)
  doAssert c.id == foundId and laxId in c.outOfRule, "but not under the charter in force"
  # an electorate that swaps in a non-member, likewise
  var packed = parseJson(amendmentEffect(charterInForce(founded, driverFor), renamed))
  packed["electorate"] = %(@[idOf(alice), idOf(dave), idOf(carol)])
  let packedJson = $packed
  let (packedId, packedEvs) = propose(packedJson)
  evs = founded & packedEvs & @[sign(alice, packedId, packedJson), sign(dave, packedId, packedJson)]
  doAssert charterInForce(evs, driverFor).id == foundId, "an electorate the charter does not name"
  # a founding that does not ask every member it names is not a founding
  var thin = parseJson(foundingEffect(circle))
  thin["k"] = %2
  doAssert driverFor(CharterKind).signRefusal(effectFromJson($thin)).len > 0,
           "a founding decided by fewer than all it names is refused at signing"
  echo "4. a lax rule, a packed electorate, a thin founding: none takes force OK"

# ── 5. competing amendments of one charter: one wins, the same everywhere ─────
var other = circle.copy()
other["purpose"] = %"save together, lend from the pot"
let otherJson = amendmentEffect(charterInForce(founded, driverFor), other)
let (otherId, otherEvs) = propose(otherJson)
let both = founded & amendEvs & otherEvs &
           @[sign(alice, amendId, amendJson), sign(bob, amendId, amendJson),
             sign(bob, otherId, otherJson), sign(carol, otherId, otherJson)]
block:
  let c = charterInForce(both, driverFor)
  let winner = min(amendId, otherId)
  doAssert c.id == winner and c.superseded == @[max(amendId, otherId)], c.id
  var r = initRand(267)
  for trial in 0 ..< 20:
    var evs = both & both.filterIt(r.rand(1) == 0)   # duplicates
    r.shuffle(evs)                                     # reorder
    let c2 = charterInForce(evs, driverFor)
    doAssert c2.id == c.id and c2.history == c.history and c2.superseded == c.superseded
  echo "5. two agreed amendments of one charter: the lower id holds, the other superseded; ",
       "20 reorders with duplicates converge (R-2/R-3) OK"

# ── 6. a chain of amendments; a stale prev never takes force ──────────────────
block:
  let after = founded & amendEvs & @[sign(alice, amendId, amendJson), sign(bob, amendId, amendJson)]
  var third = renamed.copy()
  third["rules"]["issue-quest"] = %("lez-multisig@lez:local:" & repeat("ab", 32))
  let thirdJson = amendmentEffect(charterInForce(after, driverFor), third)
  let (thirdId, thirdEvs) = propose(thirdJson)
  # and one still naming the founding charter as prev, agreed after the first amendment
  let staleJson = amendmentEffect(charterInForce(founded, driverFor), other)
  let (staleId, staleEvs) = propose(staleJson)
  let evs = after & thirdEvs & staleEvs &
            @[sign(bob, thirdId, thirdJson), sign(carol, thirdId, thirdJson),
              sign(alice, staleId, staleJson), sign(carol, staleId, staleJson)]
  let c = charterInForce(evs, driverFor)
  doAssert c.history[0] == foundId
  # the stale one competes with amendId (both name the founding charter), not with third
  if amendId < staleId:
    doAssert c.history == @[foundId, amendId, thirdId] and c.body.rules.anyIt(it[0] == "issue-quest")
    doAssert staleId in c.superseded
  else:
    doAssert c.history == @[foundId, staleId] and amendId in c.superseded
  echo "6. amendments chain by prev; a competing one of an older charter is superseded OK"

# ── 7. the charter's account, checked against what the room was shown ─────────
block:
  let (_, body, _) = parseCharterBody(circle)
  doAssert charterAccountProblems(body, @[]).len == 1, "an account no member disclosed"
  let shown = RoomAccount(id: "lez:local:" & repeat("ab", 32), family: "lez.multisig-program",
                          chain: "lez:local", address: repeat("ab", 32), threshold: 2,
                          signers: @[repeat("01", 32), repeat("02", 32), repeat("03", 32)])
  doAssert charterAccountProblems(body, @[shown]).len == 0, $charterAccountProblems(body, @[shown])
  var short = shown
  short.signers = short.signers[0 .. 1]
  doAssert charterAccountProblems(body, @[short]).len == 1, "the multisig has fewer members than the charter names"
  echo "7. the charter's multisig is checked against the room's disclosure OK"

# ── 8. a rival founding by fewer people never displaces the room's ────────────
# Anyone may found a charter naming only themselves and agree to it alone; an intent id is
# the proposer's to grind (vary the name until it sorts first). Which founding holds is
# decided by whom it names, never by id.
block:
  var lower, higher = 0
  for i in 0 ..< 24:
    let solo = foundingEffect(circleTemplate(name = "carol's circle " & $i, purpose = "",
                                             members = @[idOf(carol)], amendK = 1))
    let (soloId, soloEvs) = propose(solo)
    var evs = founded & soloEvs & @[sign(carol, soloId, solo)]
    let c = charterInForce(evs, driverFor)
    doAssert c.found and c.id == foundId and soloId in c.superseded, "rival " & $i & " displaced the room's charter"
    if soloId < foundId: inc lower else: inc higher
    # and in any order
    var rng = initRand(i)
    rng.shuffle(evs)
    doAssert charterInForce(evs, driverFor).id == foundId
  doAssert lower > 0, "some rival ids sort below the room's founding: the rule was exercised"
  # a re-founding naming everyone the first named (and more) is agreed by all of them: it holds
  let wider = foundingEffect(circleTemplate(name = "with dave", purpose = "",
                                            members = members & @[idOf(dave)], amendK = 2))
  let (widerId, widerEvs) = propose(wider)
  let evs = founded & widerEvs & @[sign(alice, widerId, wider), sign(bob, widerId, wider),
                                   sign(carol, widerId, wider), sign(dave, widerId, wider)]
  doAssert charterInForce(evs, driverFor).id == widerId and foundId in charterInForce(evs, driverFor).superseded
  # two foundings by groups neither of which includes the other: contested, none in force
  let ab = foundingEffect(circleTemplate(name = "ab", purpose = "", members = @[idOf(alice), idOf(bob)], amendK = 1))
  let cd = foundingEffect(circleTemplate(name = "cd", purpose = "", members = @[idOf(carol), idOf(dave)], amendK = 1))
  let (abId, abEvs) = propose(ab)
  let (cdId, cdEvs) = propose(cd)
  let split = abEvs & cdEvs & @[sign(alice, abId, ab), sign(bob, abId, ab), sign(carol, cdId, cd), sign(dave, cdId, cd)]
  let c = charterInForce(split, driverFor)
  doAssert not c.found and sorted(c.contested) == sorted(@[abId, cdId]), $c.contested
  echo "8. a rival founding by fewer never displaces the room's (", lower, " of 24 sorted first); ",
       "a wider one agreed by all holds; disjoint ones are contested OK"

# ── 9. the charter driver conforms ────────────────────────────────────────────
block:
  let d = driverFor(CharterKind)
  let e = effectFromJson(foundJson)
  let t = effectFromJson(amendJson)
  let m = canonicalize(d, e)
  let r = checkConformance(d, e, t, Contribution(bytes: @(edSign(alice, m.bytes))))
  doAssert r.allPass(), "charter driver must conform: failed " & $r.failed()
  echo "9. the charter driver conforms (", r.checks.len, " checks) OK"

echo "charter_test: all OK"
