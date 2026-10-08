## derived-exo-dcc.5 s2: payTo is the creditor's own subaddress on the agreed network — the
## creditor's client refuses to propose or agree to a payTo its own wallet does not list, an
## address for another network, or an integrated address; no client treats as payable a
## request whose payTo fails Monero address validation for its chain.
##
## STEPPER: state = one case of payTo {Alice's own listed subaddress, another wallet's
## subaddress, Alice's subaddress written for another network, Alice's integrated address,
## Alice's subaddress with one character changed (its checksum broken)} x {Alice proposes;
## Bob proposes on her behalf and Alice agrees} x network {mainnet, stagenet, testnet}: 30
## cases, chained case -> case+1. Each runs the REAL propose / agree path
## (coordination/xmr_request.nim) over each member's own fake wallet. Where Bob's own client
## refuses to propose an invalid payTo, the proposal is put in the log as a client that
## skips every check would (policy, propose, context), so every other client still has to
## judge it. The rule, stated alone:
##   * Alice's propose or agree is accepted iff her wallet lists payTo, its network is the
##     agreed chain's and it is not integrated; refused, nothing she signed is in the log;
##   * Bob's client refuses to propose a payTo that is not a valid address on the chain;
##   * the request is payable (agreed, every debtor's link derivable) on every member's
##     client iff payTo is Alice's own listed subaddress — never for an invalid payTo, even
##     once Bob and Carol have tried to agree.
## Run by hand (no argv), it checks all 30 with doAssert.

import std/[json, strutils]
import ../../src/coordination/attest      # contextEvent, SigningContext
import ./xmr_room
import ./oracle_emit

const Kinds = ["own", "another-wallet", "other-network", "integrated", "bad-checksum"]
const N = 30

proc decode(k: int): tuple[kind, who, net: int] = (k div 6, (k mod 6) div 3, k mod 3)

proc otherNet(n: MoneroNetwork): MoneroNetwork =
  case n
  of xmrMainnet: xmrStagenet
  of xmrStagenet: xmrTestnet
  of xmrTestnet: xmrMainnet

proc broken(a: string): string =
  ## one character changed, inside Monero's alphabet: the checksum no longer matches
  result = a
  let i = 30
  result[i] = (if result[i] == 'B': 'C' else: 'B')

proc forcePropose(x: XmrRoom, who, effectJson: string): string =
  ## What a client that skips every check would put in the log.
  let (s, _) = x.r.sessionOf(who)
  let policy = xmrPolicy(x.chain)
  let id = intentIdFor(effectJson, policy)
  s.publish(policyDeclEvent(id, policy))
  s.publish(proposeEvent(id, effectJson))
  s.publish(contextEvent(id, SigningContext(environment: x.chain, account: x.chain & ":forced", slot: id,
                                            expiry: Now + uint64(Ttl))))
  id

proc approvedBy(x: XmrRoom, id, who: string): bool =
  x.r.sync()
  for v in reduceIntentViews(x.r.dave.roomEvents(), xmrFor):
    if v.id == id:
      for g in approvalGrades(x.r.dave.roomEvents(), xmrFor, id):
        if g.who == partName(identityOf(who)) and g.grade != agRejected: return true
  false

proc correct(k: int): bool =
  let (ki, who, ni) = decode(k)
  let chain = XmrChains[ni]
  let net = netOf(chain)
  var x = newXmrRoom("/muster/1/xmr-payto-" & $k & "/proto", chain)
  let w = x.wallet("alice")
  let mine = w.mint("muster:probe")
  let payTo = case Kinds[ki]
    of "own": mine.address
    of "another-wallet": walletAddress("wallet-dave", net, mine.index)
    of "other-network": walletAddress("wallet-alice", otherNet(net), mine.index)
    of "integrated": walletAddress("wallet-alice", net, mine.index, makIntegrated)
    else: broken(mine.address)
  let valid = acceptablePayTo(payTo, chain).ok
  let should = Kinds[ki] == "own"
  let effect = x.requestJson(payTo, @[(bob, "700"), (carol, "300")], "payto")
  var id = ""
  if who == 0:
    # Alice proposes her own request: proposing is her agreement
    let r = x.propose("alice", effect)
    if r.startsWith("0x") != should: return false
    if r.startsWith("0x"):
      id = r
    else:
      # refused, and nothing published under it
      x.r.sync()
      if effectJsonOf(x.r.bob.roomEvents(), intentIdFor(effect, xmrPolicy(chain))).len > 0: return false
      id = forcePropose(x, "dave", effect)   # someone else's client puts it there anyway
  else:
    # Bob proposes on her behalf
    let r = x.propose("bob", effect)
    if r.startsWith("0x") != valid: return false          # his client refuses an invalid payTo
    id = (if r.startsWith("0x"): r else: forcePropose(x, "bob", effect))
    x.r.sync()
    let a = x.agree("alice", id)
    let accepted = a in ["collecting", "executable"]
    if accepted != should: return false
  if approvedBy(x, id, "alice") != should: return false
  # the debtors try to agree whatever it is
  discard x.agree("bob", id)
  discard x.agree("carol", id)
  x.r.sync()
  for viewer in ["alice", "bob", "carol", "dave"]:
    let (s, _) = x.r.sessionOf(viewer)
    if xmrPayable(s.roomEvents(), xmrFor, id) != should: return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (ki, who, ni) = decode(k)
    doAssert correct(k), "case " & $k & ": payTo " & Kinds[ki] & ", " & (if who == 0: "Alice proposes" else: "Bob on her behalf") &
                         ", " & XmrChains[ni] & " — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
