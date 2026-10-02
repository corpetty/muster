## derived-exo-a90 s2/c2: a split's state — who agreed, which parts are settled and
## confirmed, its lifecycle — is a pure function of the room's log: the same event set in
## any order, with any duplication, folds to the identical state on every member.
##
## STEPPER: over a fixed eight-event set for a two-debtor split: the proposal, both
## debtors' agreements and the creditor's (a party since exo-770), A's settled report, A's
## confirmation, a FORGED settled report for B (authored by A — the fold must drop it
## wherever it lands), and a bare final (which must never move a parts intent). State =
## which event is delivered FIRST (eight states, chained head -> head+1); each state folds
## EVERY order of the remaining seven (5040), as-is AND with every event delivered twice,
## and the view — lifecycle, approvals, threshold, and every part's settled / confirmed /
## tx / authors — must equal the identity order's. Eight states x 5040 orders = all 40320
## orders, at eight grader calls rather than 40320 (each call is a separate `nim r`). Run
## by hand (no argv), it checks all 40320 with doAssert.

import std/[json, algorithm]
import ../../src/intents/materialization
import ./split_room
import ./oracle_emit

let drv = newSplitDriver(EvmSplitFamily, EvmChain)
# the pure fold, as a member computes it: every intent here is this split
let dfor: DriverFor = proc(p: string): Driver = drv
let effect = splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                             evenShares("900", alice, @[bob, carol]), "convergence")
# The eight events carry no policy declaration, so the id is the effect's alone: an id
# counts only as the content address of what is filed under it (exo-dbd), and `dfor`
# folds every kind under the split driver anyway.
let id = intentIdFor(effect)
let mat = canonicalize(drv, effectFromJson(effect))
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc agreement(ks: Keystore): Event =
  let s = hx(ks.edSign(mat.bytes))
  contributeEvent(id, contributorOf(drv, effect, s), s)

let events = @[
  proposeEvent(id, effect),
  agreement(bobKs),
  agreement(carolKs),
  agreement(aliceKs),                                           # the creditor agrees too
  partEvent(id, partName(bob), "settled", bob, "0xa1"),
  partEvent(id, partName(bob), "confirmed", alice, "0xa1"),
  partEvent(id, partName(carol), "settled", bob, "0xforged"),   # wrong author: never counts
  finalEvent(id, chainRef = "0xbare")]                          # names no author: never moves it

type View = tuple[state: string, approvals, threshold: int, parts: seq[PartView]]
proc viewOf(evs: seq[Event]): View =
  for v in reduceIntentViews(evs, dfor):
    if v.id == id: return (v.state, v.approvals, v.threshold, v.parts)
  ("absent", 0, 0, @[])

let reference = viewOf(events)
doAssert reference.state == "settling" and reference.approvals == 3 and reference.threshold == 3 and
         reference.parts.len == 2,
         "the reference view is the one the rule gives: " & $reference.state

proc correct(perm: seq[int]): bool =
  var order: seq[Event]
  for i in perm: order.add events[i]
  viewOf(order) == reference and viewOf(order & order) == reference

proc headCorrect(h: int): bool =
  ## every order that delivers event h first
  var rest: seq[int]
  for i in 0 ..< events.len:
    if i != h: rest.add i
  while true:
    if not correct(@[h] & rest): return false
    if not rest.nextPermutation(): break
  true

proc state(h: int): JsonNode = %*{"head": h, "decision_correct": headCorrect(h)}

let arg = oracleStateArg()
if arg == nil:
  var p = @[0, 1, 2, 3, 4, 5, 6, 7]
  var n = 0
  while true:
    doAssert correct(p), "order " & permString(p) & " folds to a different view"
    inc n
    if not p.nextPermutation(): break
  doAssert n == 40320
let here = oracleStateInt(arg, "head", 0)
emitSuccessors(@[state((here + 1) mod events.len)])
