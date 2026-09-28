## derived-exo-a90 s1/c1: the payment a debtor's wallet signs is exactly the transfer
## derived from the agreed split — their share, to payTo, in its asset, on its chain; no
## caller- or UI-supplied value changes it; nothing is paid before every named debtor
## agreed, twice, for another's share, or against an expired agreement; a malformed split
## is refused before anyone can agree (invariant 1).
##
## STEPPER: state = one case of split {well-formed, shares above the total, a repeated
## debtor, a non-canonical amount} x payer {Bob — debtor A, Carol — debtor B, Alice — the
## creditor, Dave — a member the split does not name} x stage {collecting — only Bob
## agreed, agreed, Bob already paid} x clock {before expiry, after}: 96 cases, chained
## case -> case+1. Each case runs the REAL live path in-process over a fake ledger, in a
## room that also holds a decoy split (other amounts, another payTo) everyone agreed to.
## A transfer must be sent iff the payer is a debtor of the well-formed split, it is agreed,
## the payer has not paid, and the agreement has not expired — and when sent it must equal
## (share, payTo, asset, chain) read INDEPENDENTLY from the target split's proposal in the
## log. A malformed split must be refused at propose: no intent, nothing to agree to. Run
## by hand (no argv), it checks all 96 with doAssert.

import std/[json, strutils]
import ../../src/intents/materialization
import ../../src/coordination/parts
import ./split_room
import ./oracle_emit

const Splits = ["well-formed", "sum-above-total", "repeated-debtor", "non-canonical"]
const Payers = ["bob", "carol", "alice", "dave"]
const Stages = ["collecting", "agreed", "bob-paid"]
const Clocks = ["before", "after"]
const N = 96

proc decode(k: int): tuple[split, payer, stage, clock: string] =
  (Splits[k div 24], Payers[(k mod 24) div 6], Stages[(k mod 6) div 2], Clocks[k mod 2])

proc sortedPair(a, b: (string, string)): seq[(string, string)] =
  (if a[0] < b[0]: @[a, b] else: @[b, a])

proc rawSplit(total: string, shares: seq[(string, string)], memo: string, payTo = AlicePayTo): string =
  ## A split effect as a (possibly malformed) proposer might send it — no normalizing.
  var arr = newJArray()
  for (w, a) in shares: arr.add %*{"who": w, "amount": a}
  $(%*{"effect": "split", "chain": EvmChain, "asset": "ETH", "total": total, "creditor": alice,
       "payTo": payTo, "shares": arr, "memo": memo})

proc fromLog(r: Room4, id, who: string): tuple[amount, to, asset, chain: string] =
  ## What the agreed split says this payer owes, read from the proposal in the log — not
  ## through the driver, so the check is independent of the code under test.
  r.sync()
  for e in r.alice.roomEvents():
    if e.key == "intent/" & id & "/propose":
      let j = parseJson(e.value)
      for s in j["shares"]:
        if s["who"].getStr() == identityOf(who):
          return (s["amount"].getStr(), j["payTo"].getStr(), j["asset"].getStr(), j["chain"].getStr())

proc correct(k: int): bool =
  let (split, payer, stage, clock) = decode(k)
  var r = newRoom4("/muster/1/split-derived-" & $k & "/proto")
  if split != "well-formed":
    let bad = (case split
      of "sum-above-total": rawSplit("100", sortedPair((bob, "60"), (carol, "60")), "bad")
      of "repeated-debtor": rawSplit("100", @[(bob, "10"), (bob, "10")], "bad")
      else: rawSplit("100", @[(bob, "030")], "bad"))
    let refused = r.propose(EvmPolicy, bad)
    return refused.startsWith("refused:") and r.stateOf(intentIdFor(bad, EvmPolicy)) == "unknown"
  let ledger = newFakeLedger()
  let decoy = rawSplit("90", sortedPair((bob, "20"), (carol, "40")), "decoy",
                       payTo = "0x1111111111111111111111111111111111111111")
  let target = splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                               evenShares("900", alice, @[bob, carol]), "target")
  let did = r.propose(EvmPolicy, decoy)
  let id = r.propose(EvmPolicy, target)
  if not did.startsWith("0x") or not id.startsWith("0x"): return false
  discard r.agree("bob", did)
  discard r.agree("carol", did)
  discard r.agree("bob", id)
  if stage != "collecting": discard r.agree("carol", id)
  if stage == "bob-paid":
    let (sb, ksb) = r.sessionOf("bob")
    let seam = newFakePartSeam(ledger, "bob")
    let (o, pp) = liveSettlePartSend(sb, ksb, splitFor, id, seam, Now)
    if o.len > 0: return false
    ledger.mine()
    if liveSettlePartComplete(sb, ksb, splitFor, seam, pp) != "submitted": return false
  let before = ledger.sent.len
  let (s, ks) = r.sessionOf(payer)
  let now = (if clock == "before": Now else: Now + uint64(Ttl) + 1)
  discard liveSettlePartSend(s, ks, splitFor, id, newFakePartSeam(ledger, payer), now)
  let sent = ledger.sent.len > before
  let shouldSend = payer in ["bob", "carol"] and stage != "collecting" and
                   not (stage == "bob-paid" and payer == "bob") and clock == "before"
  if sent != shouldSend: return false
  if sent:
    if ledger.sent.len != before + 1: return false
    let t = ledger.sent[^1].transfer
    let want = fromLog(r, id, payer)
    if want.amount.len == 0: return false
    if t.amount != want.amount or t.to != want.to or t.asset != want.asset or t.chain != want.chain: return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (split, payer, stage, clock) = decode(k)
    doAssert correct(k), "case " & $k & ": " & split & " split, " & payer & " pays at stage " & stage &
                         ", " & clock & " expiry — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
