## derived-exo-a90.20 s6: a split past its expiry is renewed as a settle-up of exactly its
## unpaid shares, which everyone they name agrees to again under a fresh expiry; renewing
## again after a renewal lapsed is a new intent; re-proposing an identical expired split is
## refused with a reason (exo-a90.15).
##
## STEPPER: state = one case of the split {agreed, nothing paid; agreed, Bob's share paid;
## final; never agreed} x clock {before its expiry; long after it} x earlier renewals {none;
## one live; one that lapsed unpaid} x family {evm.split; lez.split, the private split}: 48
## cases (before its expiry there are no earlier renewals: those rows coincide), chained
## case -> case+1. The split — Bob and Carol owing Alice 300 each — lasts an hour. Each case
## runs the REAL live path over a fake ledger. The rule, stated alone:
##   * the private split is never renewed this way: renewalOf gives a reason;
##   * a final split, one never agreed, and one whose unpaid shares a live renewal already
##     covers have nothing to renew: renewalOf gives a reason;
##   * otherwise renewalOf covers exactly the unpaid shares, each as the split says it (its
##     debtor, the creditor, the amount, payTo) — an earlier renewal that lapsed covers
##     nothing any more;
##   * a renewal is a new intent (never a lapsed renewal's id); everyone it names agrees to
##     it under its fresh expiry, and paying through it makes the split final;
##   * re-proposing the identical split answers "expired-duplicate" iff it has expired.
## Run by hand (no argv), it checks all 48 with doAssert.

import std/[json, strutils, sequtils, algorithm]
import ../../src/intents/materialization
import ../../src/coordination/parts
import ../../src/coordination/covers
import ../../src/coordination/settle_up
import ./split_room
import ./oracle_emit

const States = ["agreed", "one-paid", "final", "never-agreed"]
const Clocks = ["before", "after"]
const Earlier = ["none", "live", "lapsed"]
const Families = ["evm", "lez"]
const N = 48
const LezPayTo = "priv:" & "ab".repeat(32) & ":" & "cd".repeat(33)

proc decode(k: int): tuple[st, clock, earlier, family: string] =
  (States[k div 12], Clocks[(k mod 12) div 6], Earlier[(k mod 6) div 2], Families[k mod 2])

let later = Now + 2 * uint64(Ttl) + CoverReleaseGraceS + 10

proc correct(k: int): bool =
  let (st, clock, earlierRaw, family) = decode(k)
  let at = (if clock == "before": Now else: later)
  let earlier = (if clock == "before": "none" else: earlierRaw)
  let lez = family == "lez"
  var r = newRoom4("/muster/1/probe-renew-" & $k & "/proto")
  var seqNo = 0'u64
  proc propose(policy, effect: string, atTime: uint64): string =
    inc seqNo
    liveProposeIntent(r.alice, aliceKs, splitFor, policy, effect, int64(atTime), seqNo,
                      account = policy.split('@')[1] & ":alice", ttlSec = Ttl)
  proc agreeAt(who, id: string, atTime: uint64): string =
    let (s, ks) = r.sessionOf(who)
    liveContribute(s, ks, splitFor, id, "", "", LinkContext(account: "probe", slot: "0", expiry: later + 86_400), atTime)
  let ledger = newFakeLedger()
  proc pay(who, id: string, atTime: uint64): bool =
    let (s, ks) = r.sessionOf(who)
    let seam = newFakePartSeam(ledger, who)
    let (o, pp) = liveSettlePartSend(s, ks, splitFor, id, seam, atTime)
    if o.len > 0: return false
    ledger.mine()
    discard liveSettlePartComplete(s, ks, splitFor, seam, pp)
    r.sync()
    true
  let policy = (if lez: LezPolicy else: EvmPolicy)
  let effect = (if lez: splitEffectJson(LezChain, "LEZ", "900", alice, LezPayTo,
                                        evenShares("900", alice, @[bob, carol], distinctAmounts = true), "brunch")
                else: splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                                      evenShares("900", alice, @[bob, carol]), "brunch"))
  let id = propose(policy, effect, Now)
  if not id.startsWith("0x"): return false
  r.sync()
  if st != "never-agreed":
    discard agreeAt("bob", id, Now)
    discard agreeAt("carol", id, Now)
    r.sync()
  if not lez and st in ["one-paid", "final"]:
    if not pay("bob", id, Now): return false
  if not lez and st == "final":
    if not pay("carol", id, Now): return false
    discard liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
    r.sync()
    if intentState(r.alice.roomEvents(), splitFor, id) != "final": return false
  # an earlier renewal, live or lapsed (both past the split's expiry)
  var earlierId = ""
  if earlier != "none" and not lez and st in ["agreed", "one-paid"]:
    let madeAt = (if earlier == "live": later - 10 else: Now + uint64(Ttl) + 1)
    let e0 = renewalOf(r.alice.roomEvents(), splitFor, id, madeAt)
    if e0.why.len > 0: return false
    earlierId = propose(EvmPolicy, e0.effectJson, madeAt)
    r.sync()
    for c in e0.covers: discard agreeAt((if c.debtor == bob: "bob" else: "carol"), earlierId, madeAt)
    r.sync()
  # the rule, stated alone
  let unpaid = (if st == "agreed": @[bob, carol] elif st == "one-paid": @[carol] else: @[])
  let renewable = not lez and st in ["agreed", "one-paid"] and earlier != "live"
  let rn = renewalOf(r.alice.roomEvents(), splitFor, id, at)
  if renewable != (rn.why.len == 0): return false
  if renewable:
    if rn.covers.mapIt(it.debtor).sorted() != unpaid.sorted(): return false
    for c in rn.covers:
      if c.intent != id or c.creditor != alice or c.amount != "300" or c.payTo != AlicePayTo: return false
    let rid = propose(EvmPolicy, rn.effectJson, at)
    if not rid.startsWith("0x") or rid == earlierId: return false
    r.sync()
    var state = ""
    for c in rn.covers: state = agreeAt((if c.debtor == bob: "bob" else: "carol"), rid, at)
    if state != "executable": return false
    # paid through the renewal — each debtor it covers pays their own part — the split is final
    for c in rn.covers:
      if not pay((if c.debtor == bob: "bob" else: "carol"), rid, at): return false
    discard liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
    r.sync()
    if intentState(r.alice.roomEvents(), splitFor, rid) != "final": return false
    discard settleCovered(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
    discard liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
    r.sync()
    if intentState(r.alice.roomEvents(), splitFor, id) != "final": return false
  # the identical split again
  let again = propose(policy, effect, at)
  if (again == "expired-duplicate") != (clock == "after"): return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (st, clock, earlier, family) = decode(k)
    doAssert correct(k), "case " & $k & ": " & family & " split " & st & ", clock " & clock & ", earlier renewal " &
                         earlier & " — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
