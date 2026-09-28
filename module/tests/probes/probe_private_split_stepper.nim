## derived-exo-a90 s6/c6: the private split names no one on chain — every share is a
## distinct amount; a debtor pays only shielded to shielded (a public source is refused);
## a part is confirmed only when the creditor's own scan finds an unclaimed note of exactly
## that share at payTo — a payer's report alone never confirms it.
##
## STEPPER: state = one case of payer source {shielded, public} x note {exactly Bob's share
## at payTo, share + 1, share - 1, exactly the share but at another of Alice's key nodes,
## none, exactly the share but already claimed by another split} x report {Bob reported
## paying, not}, plus one case of a private split with two equal shares: 25 cases, chained
## case -> case+1. Each case runs two checks, each in its own room on its own shared fake
## LEZ chain (every member a separate wallet; a note lands only in its recipient's wallet):
##   * the SOURCE — Bob pays through the live path: from his shielded account it is sent
##     and takes the private rail; from his public account it is refused and nothing moves;
##   * the NOTE — an unrelated wallet sends the note the case names, Bob reports or not,
##     and Alice's pump runs: Bob's part is confirmed iff he reported AND the note is
##     exactly his share AND at payTo AND unclaimed; a confirmation records a note HASH.
## The equal-shares case must be refused at propose. Run by hand (no argv), it checks all
## 25 with doAssert.

import std/[json, strutils]
import ../../src/wallet/[types, lez_core, lez_adapter]
import ../../src/intents/materialization   # PartTransfer
import ../../src/coordination/parts
import ../../src/coordination/parts_lez
import ./split_room
import ./oracle_emit

const Sources = ["shielded", "public"]
const Notes = ["exact", "plus-one", "minus-one", "other-key-node", "none", "claimed"]
const Reports = ["reported", "silent"]
const N = 25
const Total = "900000000"

proc decode(k: int): tuple[source, note, report: string] =
  (Sources[k div 12], Notes[(k mod 12) div 2], Reports[k mod 2])

type Wallets = object
  chain: FakeLezChain
  aliceCore: FakeLezCore
  alice, bob, eve: LezAdapter

proc wallets(): Wallets =
  result.chain = newFakeLezChain()
  result.aliceCore = newFakeLezCore(result.chain)
  result.alice = newLezAdapter(result.aliceCore)
  result.bob = newLezAdapter(newFakeLezCore(result.chain))
  result.eve = newLezAdapter(newFakeLezCore(result.chain))    # an unrelated payer

proc form(w: LezAdapter, ks: Keystore, f: AccountForm): Account =
  for a in w.accounts(ks):
    if a.form == f: return a

proc payToOf(w: LezAdapter, ks: Keystore): string =
  for (f, address) in w.receiveAddresses(ks):
    if f == "shielded": return address

proc splitJson(payTo, memo: string): string =
  splitEffectJson(LezChain, "LEZ", Total, alice, payTo,
                  evenShares(Total, alice, @[bob, carol], distinctAmounts = true), memo)

proc bobShare(effect: string): string =
  for s in parseJson(effect)["shares"]:
    if s["who"].getStr() == bob: return s["amount"].getStr()

proc addDec(a: string, d: int): string = $(parseBiggestInt(a) + d)

proc sourceCorrect(k: int, source: string): bool =
  let w = wallets()
  w.chain.fund(form(w.bob, bobKs, afShielded).id, "5000000000")
  w.chain.fund(form(w.bob, bobKs, afPublic).id, "5000000000")
  var r = newRoom4("/muster/1/private-source-" & $k & "/proto")
  let effect = splitJson(payToOf(w.alice, aliceKs), "source")
  let id = r.propose(LezPolicy, effect)
  if not id.startsWith("0x"): return false
  discard r.agree("bob", id)
  if r.agree("carol", id) != "executable": return false
  let seam = (if source == "shielded": newLezPartSeam(LezChain, w.bob, bobKs)
              else: newLezPartSeam(LezChain, w.bob, bobKs, payFrom = form(w.bob, bobKs, afPublic)))
  proc pubBalance(): string = w.bob.balance(form(w.bob, bobKs, afPublic), w.bob.describe().nativeAsset).raw
  let pubBefore = pubBalance()
  let (outcome, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id, seam, Now)
  let notes = w.alice.receivedNotes(aliceKs)
  if source == "shielded":
    outcome == "" and seam.lastRail == tfPrivate and notes.len == 1 and notes[0].raw == bobShare(effect)
  else:
    outcome.startsWith("refused:") and notes.len == 0 and
      pubBalance() == pubBefore

proc noteCorrect(k: int, note, report: string): bool =
  let w = wallets()
  w.chain.fund(form(w.eve, daveKs, afShielded).id, "9000000000")
  let payTo = payToOf(w.alice, aliceKs)
  var r = newRoom4("/muster/1/private-note-" & $k & "/proto")
  let aliceSeam = newLezPartSeam(LezChain, w.alice, aliceKs)
  let effect = splitJson(payTo, "target")
  let share = bobShare(effect)
  let eveSeam = newLezPartSeam(LezChain, w.eve, daveKs)
  proc send(to, amount: string): bool =
    eveSeam.sendPart(PartTransfer(ok: true, chain: LezChain, asset: "LEZ", to: to, amount: amount)).ok
  if note == "claimed":
    # another split claims the one exact note first
    let id0 = r.propose(LezPolicy, splitJson(payTo, "earlier"))
    discard r.agree("bob", id0)
    discard r.agree("carol", id0)
    r.bob.publishAuthored(bobKs, partEvent(id0, partName(bob), "settled", bob, "tx-earlier"))
    if not send(payTo, share): return false
    if liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam).len != 1: return false
  let id = r.propose(LezPolicy, effect)
  if not id.startsWith("0x"): return false
  discard r.agree("bob", id)
  if r.agree("carol", id) != "executable": return false
  case note
  of "exact": (if not send(payTo, share): return false)
  of "plus-one": (if not send(payTo, addDec(share, 1)): return false)
  of "minus-one": (if not send(payTo, addDec(share, -1)): return false)
  of "other-key-node":
    let kn2 = w.aliceCore.createAccount(lakPrivate)       # another key node Alice holds
    if not send("priv:" & kn2.npk & ":" & kn2.vpk, share): return false
  else: discard                                             # none / claimed: nothing new
  if report == "reported":
    r.bob.publishAuthored(bobKs, partEvent(id, partName(bob), "settled", bob, "tx-claimed"))
  discard liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam)
  let p = r.partView(id, "bob")
  let expected = report == "reported" and note == "exact"
  if p.confirmed != expected: return false
  if p.confirmed:
    # the room records a hash of the note, never the note's id
    if not p.tx.startsWith("note:") or p.tx.len != "note:".len + 32 or "recv" in p.tx: return false
  true

proc correct(k: int): bool =
  if k == 24:
    # a private split with two equal shares cannot be told apart by amount: refused
    let w = wallets()
    var r = newRoom4("/muster/1/private-equal/proto")
    let same = splitEffectJson(LezChain, "LEZ", Total, alice, payToOf(w.alice, aliceKs),
                               evenShares(Total, alice, @[bob, carol]), "equal")
    let refused = r.propose(LezPolicy, same)
    return refused.startsWith("refused:") and "differ" in refused
  let (source, note, report) = decode(k)
  sourceCorrect(k, source) and noteCorrect(k, note, report)

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    doAssert correct(k), "case " & $k & " (" & (if k == 24: "equal shares" else: $decode(k)) & ") judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
