## derived-exo-a90 s3/c3: what the room says about a part is only what the named people
## disclosed — "settled" counts only if the debtor it names authored and signed it,
## "confirmed" only if the creditor did; another debtor's, an outsider's, a forged, or
## another room's report never moves it.
##
## STEPPER: state = one case of author {Bob — the debtor the part names, Carol — the
## other debtor, Alice — the creditor, Dave — a member the split does not name} x step
## {settled, confirmed} x signature {valid for this room, edited after signing, signed for
## another room}: 24 cases, chained case -> case+1 (and the last back to 0), so every case
## is evaluated once. Each case builds a fresh room, agrees the split, publishes ONE report
## on Bob's part exactly as its author's client would (or a forgery of it), and folds the
## room's authentic view. The step must count iff the author is the one it allows AND the
## signature is valid for THIS room. Run by hand (no argv), it checks all 24 with doAssert.

import std/[json, strutils]
import ./split_room
import ./oracle_emit

const Authors = ["bob", "carol", "alice", "dave"]
const Steps = ["settled", "confirmed"]
const Sigs = ["valid", "edited", "other-room"]
const N = 24

proc decode(k: int): tuple[author, step, sig: string] =
  (Authors[k div 6], Steps[(k mod 6) div 3], Sigs[k mod 3])

proc keystoreOf(who: string): Keystore =
  case who
  of "alice": aliceKs
  of "bob": bobKs
  of "carol": carolKs
  else: daveKs

proc correct(k: int): bool =
  let (author, step, sig) = decode(k)
  var r = newRoom4("/muster/1/split-authorship-" & $k & "/proto")
  let effect = splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                               evenShares("900", alice, @[bob, carol]), "authorship")
  let id = r.propose(EvmPolicy, effect)
  if not id.startsWith("0x"): return false
  if r.agree("bob", id) != "collecting" or r.agree("carol", id) != "executable": return false
  let ks = keystoreOf(author)
  let (s, _) = r.sessionOf(author)
  let report = partEvent(id, partName(bob), step, identityOf(author), "0xab12")
  var ev: Event
  case sig
  of "valid": ev = signAuthored(ks, r.topic, report)
  of "other-room": ev = signAuthored(ks, "/muster/1/some-other-room/proto", report)
  else:
    ev = signAuthored(ks, r.topic, report)
    let j = parseJson(ev.value)
    j["tx"] = %"0xcd34"                          # edited after it was signed
    ev = Event(parents: ev.parents, key: ev.key, value: $j)
  s.publish(ev)                                   # what reaches every member, as sent
  let p = r.partView(id, "bob")
  let counted = (if step == "settled": p.settled else: p.confirmed)
  let allowed = (if step == "settled": author == "bob" else: author == "alice")
  let expected = allowed and sig == "valid"
  if counted != expected: return false
  # the lifecycle follows the part: submitted on a counted settle, settling on a counted
  # confirmation, executable when nothing counted
  let want = (if not expected: "executable" elif step == "settled": "submitted" else: "settling")
  r.stateOf(id) == want

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (author, step, sig) = decode(k)
    doAssert correct(k), "a " & step & " report by " & author & " (" & sig & ") was judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
