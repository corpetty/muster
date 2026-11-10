## A room's charter through the live path (exo-267.1; docs/design/logos-world-plan.md
## Phase 1): what the hosted coordinate_charter / coordinate_propose_charter methods run,
## driven in-process over a real three-member room (LocalTransport, real keystores,
## coordination/live.nim's propose and in-app approve — never a mocked Driver).
##   1. a proposal from the circle template, with no charter in force, is a founding that
##      every member it names decides; its members default to the room's;
##   2. the three approve in-app; every member folds the same charter in force, and the
##      view names its rules, its history, and that its account was never shown the room;
##   3. a proposal now is an amendment of the charter in force, under its rule (its
##      members, its amend k): two of three put it in force on every member;
##   4. what will never take force is said so before anyone signs: an amendment under
##      another rule (out of rule), one of a charter no longer in force (stale);
##   5. a malformed body or template is refused with its reason, and nothing is proposed;
##   6. the view is a function of the event set: reordered and duplicated, the same JSON.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, sequtils, strutils, random, algorithm]
import ../src/drivers/charter
import ../src/coordination/room_charter
import ../src/coordination/accounts
import ./probes/live_room

proc encHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let ids = @[encHex(aliceKs), encHex(bobKs), encHex(room3CarolKs)]
let charterDriverFor: DriverFor = proc(kind: string): Driver = newCharterDriver(ids)

var r = newRoom3("/muster/1/charter-room/proto")
var seqNo = 0'u64

proc sessionOf(who: string): (CoordinationSession, Keystore) =
  case who
  of "alice": (r.alice, Keystore(aliceKs))
  of "bob": (r.bob, Keystore(bobKs))
  else: (r.carol, Keystore(room3CarolKs))

proc evs(who = "alice"): seq[Event] =
  r.alice.poll(); r.bob.poll(); r.carol.poll()
  sessionOf(who)[0].roomEvents()

proc proposeAs(who: string, effectJson: string): string =
  inc seqNo
  let (s, ks) = sessionOf(who)
  liveProposeIntent(s, ks, charterDriverFor, CharterKind, effectJson, int64(Now), seqNo,
                    account = r.topic, ttlSec = Ttl)

proc approve(who, id: string): string =
  let (s, ks) = sessionOf(who)
  liveContribute(s, ks, charterDriverFor, id, "", "", bindCtx(), Now)

proc view(who = "alice"): JsonNode = charterJson(evs(who), charterDriverFor, reduceAccounts(evs(who)))

let account = "lez:local:" & repeat("cd", 32)
let circleSpec = %*{"template": "circle", "name": "Tuesday circle", "purpose": "save, pay out in turn",
                    "amendK": 2, "account": account, "share": "100", "asset": "LEZ", "cadence": 604800}

# ── 1. no charter in force: the proposal founds one, decided by all it names ──────
var foundId = ""
block:
  doAssert not view()["found"].getBool()
  let p = charterProposal(charterInForce(evs(), charterDriverFor), circleSpec, ids)
  doAssert p.ok and p.founding, p.why
  let e = parseJson(p.effectJson)
  doAssert e["prev"].getStr() == "" and e["k"].getInt() == 3
  doAssert sorted(e["electorate"].getElems().mapIt(it.getStr())) == sorted(ids), "members default to the room's"
  doAssert e["body"]["rules"]["payout"].getStr() == "lez-multisig@" & account
  foundId = proposeAs("alice", p.effectJson)
  doAssert foundId.startsWith("0x"), foundId
  let v = view()
  doAssert v["proposals"].len == 1 and v["proposals"][0]["standing"].getStr() == "pending"
  doAssert v["proposals"][0]["founding"].getBool()
  echo "1. a circle from the template founds a charter all three must agree OK"

# ── 2. all three agree: the same charter in force on every member ─────────────────
block:
  doAssert approve("alice", foundId) == "collecting"
  doAssert approve("bob", foundId) == "collecting"
  doAssert not view()["found"].getBool(), "two of three founders found nothing"
  doAssert approve("carol", foundId) == "executable"
  for who in ["alice", "bob", "carol"]:
    let v = view(who)
    doAssert v["found"].getBool() and v["id"].getStr() == foundId, who
    doAssert v["body"]["name"].getStr() == "Tuesday circle"
    doAssert v["history"].getElems().mapIt(it.getStr()) == @[foundId]
  let v = view()
  doAssert v["proposals"][0]["standing"].getStr() == "in force"
  doAssert v["problems"].len == 1 and "not been disclosed" in v["problems"][0].getStr(), $v["problems"]
  doAssert v["body"]["amend"]["k"].getInt() == 2
  echo "2. founded by all three; every member folds it; its undisclosed account is flagged OK"

# ── 3. a proposal now amends the charter in force, under its own rule ─────────────
var amendId = ""
block:
  var spec = circleSpec.copy()
  spec["name"] = %"Tuesday savings circle"
  let p = charterProposal(charterInForce(evs("bob"), charterDriverFor), spec, ids)
  doAssert p.ok and not p.founding, p.why
  let e = parseJson(p.effectJson)
  doAssert e["prev"].getStr() == foundId and e["k"].getInt() == 2
  amendId = proposeAs("bob", p.effectJson)
  doAssert view()["proposals"].getElems().anyIt(it["id"].getStr() == amendId and
                                                 it["standing"].getStr() == "pending")
  doAssert approve("bob", amendId) == "collecting"
  doAssert approve("alice", amendId) == "executable"
  for who in ["alice", "bob", "carol"]:
    let v = view(who)
    doAssert v["id"].getStr() == amendId and v["body"]["name"].getStr() == "Tuesday savings circle", who
    doAssert v["history"].getElems().mapIt(it.getStr()) == @[foundId, amendId]
  echo "3. amended by two of three, the charter in force's own rule, on every member OK"

# ── 4. what can never take force is said so before anyone signs ───────────────────
block:
  let inForce = charterInForce(evs(), charterDriverFor)
  var body = parseJson($view()["body"])
  body["purpose"] = %"carol alone decides"
  # carol alone, k 1: not the charter's rule (its members, amend k 2)
  let rogue = proposeAs("carol", amendEffectJson(inForce.id, @[ids[2]], 1, body))
  # an amendment of the FOUNDING charter, which is no longer in force
  let stale = proposeAs("alice", amendEffectJson(foundId, inForce.body.members, 2, body))
  let v = view()
  let byId = proc(id: string): JsonNode =
    for p in v["proposals"]:
      if p["id"].getStr() == id: return p
  doAssert byId(rogue)["standing"].getStr() == "out of rule", $byId(rogue)
  doAssert byId(stale)["standing"].getStr() == "stale", $byId(stale)
  doAssert byId(foundId)["standing"].getStr() == "replaced"
  doAssert approve("carol", rogue) == "executable", "carol alone meets the k it names"
  doAssert view()["id"].getStr() == amendId, "an out-of-rule charter never takes force"
  doAssert view()["outOfRule"].getElems().mapIt(it.getStr()) == @[rogue]
  echo "4. out of rule and stale amendments are named before any signature, and never take force OK"

# ── 5. a malformed body or template is refused, nothing proposed ──────────────────
block:
  let inForce = charterInForce(evs(), charterDriverFor)
  for (spec, why) in [(%*{"template": "circle", "name": "", "amendK": 2}, "name"),
                      (%*{"template": "guild", "name": "x"}, "template"),
                      (%*{"template": "circle", "name": "x", "amendK": 9}, "amend k"),
                      (%*{"name": "x", "members": ids, "amend": {"k": 1}, "rules": {}}, "rule for changing rules"),
                      (%*{"name": "x", "members": ids, "amend": {"k": 1},
                          "rules": {"amend-charter": "charter"}, "orgType": "circle"}, "unknown charter field")]:
    let p = charterProposal(inForce, spec, ids)
    doAssert not p.ok and why in p.why, $spec & " -> " & p.why
  echo "5. a malformed body or template is refused with its reason OK"

# ── 6. the view is a function of the event set ────────────────────────────────────
block:
  let all = evs()
  let base = $charterJson(all, charterDriverFor, reduceAccounts(all))
  var rng = initRand(267)
  for i in 0 ..< 8:
    var shuffled = all & all[0 ..< all.len div 3]
    rng.shuffle(shuffled)
    doAssert $charterJson(shuffled, charterDriverFor, reduceAccounts(shuffled)) == base, "trial " & $i
  echo "6. reordered and duplicated, the same charter view OK"

echo "charter_room_test: a room's charter through the live path — all OK"
