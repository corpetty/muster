## derived-exo-a90.20 s1: a split is payable only once every party it names has agreed — each
## debtor, and the creditor, whose agreement is their word that payTo is theirs; anyone may
## write a split, the creditor's client refuses to agree to a payTo it does not hold
## (payto-not-mine), and a creditor who proposes agrees by proposing (exo-770).
##
## STEPPER: state = one case of who agreed {debtor A (Bob), debtor B (Carol), the creditor
## (Alice)} (8 subsets) x who proposed {Alice, the creditor; Bob, a debtor writing it on her
## behalf} x whether the creditor's client holds payTo {yes, no}: 32 cases, chained
## case -> case+1. Each runs the REAL live path in-process: the proposal, then the
## agreements the case names — the creditor's through her own client's check
## (creditorAgreeRefusal against the addresses it holds) — then Bob tries to pay his share
## over a fake ledger. The rule, stated alone: the creditor has agreed iff she proposed it,
## or agreed with a client that holds payTo; her agreement through a client that does not
## is refused "payto-not-mine"; a transfer is sent iff Bob, Carol and the creditor have all
## agreed; an on-behalf proposer is never counted as the creditor. Run by hand (no argv), it
## checks all 32 with doAssert.

import std/[json, strutils]
import ../../src/intents/materialization
import ../../src/coordination/parts
import ../../src/coordination/attest
import ./split_room
import ./oracle_emit

const N = 32
const Other = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

proc decode(k: int): tuple[mask: int, proposer: string, holds: bool] =
  (k mod 8, (if (k div 8) mod 2 == 0: "alice" else: "bob"), (k div 16) == 0)

proc has(mask, b: int): bool = (mask and (1 shl b)) != 0

proc correct(k: int): bool =
  let (mask, proposer, holds) = decode(k)
  var r = newRoom4("/muster/1/probe-creditor-agrees-" & $k & "/proto")
  let effect = splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                               evenShares("900", alice, @[bob, carol]), "creditor " & $k)
  let (ps, pks) = r.sessionOf(proposer)
  let id = liveProposeIntent(ps, pks, splitFor, EvmPolicy, effect, int64(Now), 1,
                             account = EvmChain & ":" & AlicePayTo, ttlSec = Ttl)
  if not id.startsWith("0x"): return false
  r.sync()
  if mask.has(0): discard r.agree("bob", id)
  if mask.has(1): discard r.agree("carol", id)
  var refusal = ""
  if mask.has(2):
    # the creditor agrees through her OWN client: its check, against what it holds
    refusal = creditorAgreeRefusal(effectFromJson(effect), alice, (if holds: @[AlicePayTo] else: @[Other]))
    if refusal.len == 0: discard r.agree("alice", id)
  r.sync()
  let ledger = newFakeLedger()
  discard liveSettlePartSend(r.bob, bobKs, splitFor, id, newFakePartSeam(ledger, "bob"), Now)
  let sent = ledger.sent.len == 1
  # the rule, stated alone
  let creditorAgreed = proposer == "alice" or (mask.has(2) and holds)
  let wantRefused = mask.has(2) and not holds
  let payable = mask.has(0) and mask.has(1) and creditorAgreed
  if (refusal == "payto-not-mine") != wantRefused: return false
  if refusal.len > 0 and refusal != "payto-not-mine": return false
  if sent != payable: return false
  if sent and (ledger.sent[0].transfer.to != AlicePayTo or ledger.sent[0].transfer.amount != "300"): return false
  # who the fold counts as agreed: never the on-behalf proposer as the creditor
  var agreedNames: seq[string]
  for g in approvalGrades(r.alice.roomEvents(), splitFor, id):
    if g.grade != agRejected: agreedNames.add g.who
  let aliceCounted = partName(alice) in agreedNames
  if aliceCounted != creditorAgreed: return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (mask, proposer, holds) = decode(k)
    doAssert correct(k), "case " & $k & ": agreed mask " & $mask & ", proposed by " & proposer &
                         ", creditor's client " & (if holds: "holds" else: "does not hold") & " payTo — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
