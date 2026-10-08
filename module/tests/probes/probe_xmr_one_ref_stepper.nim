## derived-exo-dcc.5 s4: one incoming transfer settles one part — a transfer already used to
## confirm one part never confirms another, and two debtors owing the same amount at the same
## subaddress are refused at proposal.
##
## STEPPER: state = one case of a two-part request (Bob owes 300, Carol 200, one subaddress),
## chained case -> case+1, each through the REAL confirm path (Alice's confirm pump over her
## MoneroPartSeam, and her by-hand confirm):
##   0. one txid's row duplicated in the history;
##   1. one txid listed twice, once with Bob's amount and once with Carol's — one transfer
##      offered to both parts — newest first;
##   2. the same, Carol's row first;
##   3. Bob's transfer confirmed, then Alice confirms Carol's part BY HAND with Bob's txid;
##   4. two transfers, one of each amount (both parts confirmed, each by its own);
##   5. case 1 across a relaunch: a fresh seam over a fresh read of the same wallet, pumped
##      twice;
##   6. a proposal of equal shares (250 each) on one subaddress;
##   7. the same equal shares, put in the log by a client that skips its checks.
## The rule, stated alone: the confirmed parts' references are pairwise distinct, and each
## is the txid of an incoming transfer in Alice's history of exactly that part's share, on
## payTo's subaddress, at least 10 deep; a reference already used confirms nothing more.
## Equal shares on one subaddress are refused at proposal on the proposer's client, and
## nobody's agreement to them counts, so they are never payable.
## Run by hand (no argv), it checks all 8 with doAssert.

import std/[json, strutils, sets]
import ../../src/coordination/attest      # contextEvent, SigningContext
import ./xmr_room
import ./oracle_emit

const N = 8

proc refsDistinctAndExact(x: XmrRoom, id: string, shares: seq[(string, string)]): bool =
  ## every confirmed part's reference: distinct, and an exact, deep, incoming transfer on payTo's
  ## subaddress in Alice's history
  x.r.sync()
  var seen: HashSet[string]
  let w = x.wallet("alice")
  for v in reduceIntentViews(x.r.alice.roomEvents(), xmrFor):
    if v.id != id: continue
    let payTo = splitOf(effectFromJson(v.effectJson)).payTo
    let idx = x.subIndexOf(payTo)
    for p in v.parts:
      if not p.confirmed: continue
      if p.tx in seen: return false
      seen.incl p.tx
      var share = ""
      for (who, a) in shares:
        if partName(who) == p.part: share = a
      var backed = false
      for r in w.rows:
        if r{"txid"}.getStr() == p.tx and r{"direction"}.getStr() == "in" and r{"amount"}.getStr() == share and
           r{"subaddrIndex"}.getStr() == $idx and r{"confirmations"}.getInt() >= 10 and not r{"failed"}.getBool():
          backed = true
      if not backed: return false
  true

proc correct(k: int): bool =
  var x = newXmrRoom("/muster/1/xmr-oneref-" & $k & "/proto", XmrStage)
  let shares = @[(bob, "300"), (carol, "200")]
  if k in [6, 7]:
    # equal shares at one subaddress
    let w = x.wallet("alice")
    let payTo = xmrMintPayTo(w, XmrStage, "muster:eq").address
    let eq = x.requestJson(payTo, @[(bob, "250"), (carol, "250")], "equal")
    var id = ""
    if k == 6:
      let r = x.propose("alice", eq)
      if r.startsWith("0x") or "differ" notin r: return false
      let rb = x.propose("bob", eq)              # nobody's client proposes it
      if rb.startsWith("0x"): return false
      return true
    let (s, _) = x.r.sessionOf("dave")
    id = intentIdFor(eq, xmrPolicy(XmrStage))
    s.publish(policyDeclEvent(id, xmrPolicy(XmrStage)))
    s.publish(proposeEvent(id, eq))
    s.publish(contextEvent(id, SigningContext(environment: XmrStage, account: "forced", slot: id,
                                              expiry: Now + uint64(Ttl))))
    x.r.sync()
    for who in ["alice", "bob", "carol"]:
      if x.agree(who, id) in ["collecting", "executable"]: return false
    for viewer in ["alice", "bob", "carol", "dave"]:
      let (sv, _) = x.r.sessionOf(viewer)
      if xmrPayable(sv.roomEvents(), xmrFor, id): return false
    return true
  let (id, payTo) = x.agreedRequest(shares, "one-ref")
  let idx = $x.subIndexOf(payTo)
  let w = x.wallet("alice")
  let t1 = txidOf(k * 10 + 1)
  let t2 = txidOf(k * 10 + 2)
  case k
  of 0:
    w.rows = @[row(t1, "in", "300", 12, idx), row(t1, "in", "300", 12, idx)]
    discard x.pump()
    if not x.partOf(id, "bob").confirmed or x.partOf(id, "carol").confirmed: return false
  of 1, 2, 5:
    let rb = row(t1, "in", "300", 12, idx)
    let rc = row(t1, "in", "200", 12, idx)
    w.rows = (if k == 2: @[rc, rb] else: @[rb, rc])
    discard x.pump()
    if k == 5:
      # relaunch: nothing held in memory, the same wallet read again
      for _ in 0 ..< 2:
        let (s, ks) = x.r.sessionOf("alice")
        discard xmrConfirmPump(s, ks, xmrFor, newMoneroPartSeam(XmrStage, w))
    # exactly one of the two parts is confirmed by t1, never both
    let b = x.partOf(id, "bob").confirmed
    let c = x.partOf(id, "carol").confirmed
    if b == c: return false
  of 3:
    w.rows = @[row(t1, "in", "300", 12, idx)]
    discard x.pump()
    if not x.partOf(id, "bob").confirmed: return false
    let (s, ks) = x.r.sessionOf("alice")
    let r = liveConfirmPart(s, ks, xmrFor, id, partName(carol), x.seamOf("alice", cmNow), t1)
    if r != "refused: that payment already settled another share": return false
    if x.partOf(id, "carol").confirmed: return false
  of 4:
    w.rows = @[row(t2, "in", "200", 15, idx), row(t1, "in", "300", 12, idx)]
    discard x.pump()
    if not (x.partOf(id, "bob").confirmed and x.partOf(id, "carol").confirmed): return false
    if x.stateOf(id) != "final": return false
  else: discard
  refsDistinctAndExact(x, id, shares)

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    doAssert correct(k), "case " & $k & ": one transfer settled more than one part, or equal shares were let through"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
