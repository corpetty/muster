## derived-exo-a90 s4/c4: a split is final exactly when every part is confirmed — any
## settled part moves an agreed split to submitted, any confirmed to settling, all
## confirmed to final; a submit or final naming no author never moves it, and no part
## report counts before everyone the split names agreed — each debtor and, since exo-770,
## the creditor.
##
## STEPPER: state = a bitmask over eight events a two-debtor split can carry — agree A,
## agree B, settled A, settled B, confirmed A, confirmed B, a bare submit, a bare final —
## on top of the proposal. Successors add one event, so the BFS from the empty set reaches
## all 256 subsets. Each state folds its events twice, without and with the creditor's
## agreement (so all 512 subsets of the nine events, at 256 grader calls), and compares
## the lifecycle AND every part's settled / confirmed flags to the rule alone (never to the
## implementation's own earlier answer). Run by hand (no argv), it checks all 512 with
## doAssert.

import std/[json, strutils]
import ../../src/intents/materialization
import ./split_room
import ./oracle_emit

const Bits = 8
const Names = ["agree A", "agree B", "settled A", "settled B", "confirmed A", "confirmed B",
               "bare submit", "bare final"]

let drv = newSplitDriver(EvmSplitFamily, EvmChain)
let dfor: DriverFor = proc(p: string): Driver = drv
let effect = splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                             evenShares("900", alice, @[bob, carol]), "finality")
let id = intentIdFor(effect, EvmPolicy)
let mat = canonicalize(drv, effectFromJson(effect))
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc agreement(ks: Keystore): Event =
  let s = hx(ks.edSign(mat.bytes))
  contributeEvent(id, contributorOf(drv, effect, s), s)

proc eventsFor(mask: int, creditorAgreed: bool): seq[Event] =
  result = @[policyDeclEvent(id, EvmPolicy), proposeEvent(id, effect)]
  if creditorAgreed: result.add agreement(aliceKs)
  let evs = [agreement(bobKs), agreement(carolKs),
             partEvent(id, partName(bob), "settled", bob, "0xa1"),
             partEvent(id, partName(carol), "settled", carol, "0xb1"),
             partEvent(id, partName(bob), "confirmed", alice, "0xa1"),
             partEvent(id, partName(carol), "confirmed", alice, "0xb1"),
             submitEvent(id, chainRef = "0xbare"), finalEvent(id, chainRef = "0xbare")]
  for b in 0 ..< Bits:
    if (mask and (1 shl b)) != 0: result.add evs[b]

proc has(mask, b: int): bool = (mask and (1 shl b)) != 0

proc expected(mask: int, creditorAgreed: bool): tuple[state: string, aSettled, aConfirmed, bSettled, bConfirmed: bool] =
  ## The rule, stated from the spec alone.
  let agreedAll = mask.has(0) and mask.has(1) and creditorAgreed
  if not agreedAll:
    return ((if mask.has(0) or mask.has(1) or creditorAgreed: "collecting" else: "proposed"),
            false, false, false, false)
  let aConf = mask.has(4)
  let bConf = mask.has(5)
  let aSet = mask.has(2) or aConf          # confirmed implies settled
  let bSet = mask.has(3) or bConf
  let st = (if aConf and bConf: "final" elif aConf or bConf: "settling"
            elif aSet or bSet: "submitted" else: "executable")
  (st, aSet, aConf, bSet, bConf)

proc correctWith(mask: int, creditorAgreed: bool): bool =
  let evs = eventsFor(mask, creditorAgreed)
  let want = expected(mask, creditorAgreed)
  if intentState(evs, dfor, id) != want.state: return false
  for v in reduceIntentViews(evs, dfor):
    if v.id != id: continue
    for p in v.parts:
      let isA = p.part == partName(bob)
      let (s, c) = (if isA: (want.aSettled, want.aConfirmed) else: (want.bSettled, want.bConfirmed))
      if p.settled != s or p.confirmed != c: return false
    return true
  false

proc correct(mask: int): bool = correctWith(mask, false) and correctWith(mask, true)

proc state(mask: int): JsonNode = %*{"events": mask, "decision_correct": correct(mask)}

let arg = oracleStateArg()
if arg == nil:
  for mask in 0 ..< (1 shl Bits):
    var named: seq[string]
    for b in 0 ..< Bits:
      if mask.has(b): named.add Names[b]
    for c in [false, true]:
      doAssert correctWith(mask, c), "lifecycle / parts disagree with the rule for {" & named.join(", ") &
        (if c: ", creditor agrees" else: "") & "}: fold says " & intentState(eventsFor(mask, c), dfor, id) &
        ", rule says " & expected(mask, c).state
let here = oracleStateInt(arg, "events", 0)
var succ: seq[JsonNode]
for b in 0 ..< Bits:
  if not here.has(b): succ.add state(here or (1 shl b))
emitSuccessors(succ)
