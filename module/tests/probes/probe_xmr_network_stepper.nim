## derived-exo-dcc.5 s7: no confirmation across networks — if the creditor's open wallet is on
## a different network from the agreed chain, nothing is confirmed from it; a stagenet
## agreement is never settled by mainnet history, or the reverse.
##
## STEPPER: state = one case of the agreed chain {mainnet, stagenet, testnet} x the network
## of the wallet Alice has open when she confirms {mainnet, stagenet, testnet, no wallet open}:
## 12 cases, chained case -> case+1. Each agrees Bob's part on the agreed chain (Alice's
## wallet on that network mints payTo), then Alice opens the case's wallet, whose history
## holds a PERFECT row — in, payTo's subaddress index, exactly the share, 20 deep — and
## Alice's REAL confirm pump runs, then her by-hand confirm from her wallet. The rule:
##   * Bob's part is confirmed iff the open wallet is on the agreed chain's network;
##   * otherwise nothing is published and the by-hand confirm names the remedy: "your
##     wallet is on another network" when one is open, "no Monero wallet is open" when none
##     is — each saying to open the agreed network's wallet (monero.wallet.unlock).
## Run by hand (no argv), it checks all 12 with doAssert.

import std/[json, strutils]
import ./xmr_room
import ./oracle_emit

const Opens = ["mainnet", "stagenet", "testnet", ""]
const N = 12

proc correct(k: int): bool =
  let chain = XmrChains[k div 4]
  let opened = Opens[k mod 4]
  var x = newXmrRoom("/muster/1/xmr-net-" & $k & "/proto", chain)
  let (id, payTo) = x.agreedRequest(@[(bob, "424242")], "network")
  let w = x.wallet("alice")
  let idx = x.subIndexOf(payTo)
  w.rows = @[row(txidOf(k), "in", "424242", 20, $idx)]
  w.network = opened                       # the wallet she has open now
  let should = opened == $netOf(chain)
  x.r.sync()
  let before = x.r.alice.roomEvents().len
  let got = x.pump()
  if (got.len == 1) != should or x.partOf(id, "bob").confirmed != should: return false
  if should: return x.stateOf(id) == "final" and x.partOf(id, "bob").tx == txidOf(k)
  if x.r.alice.roomEvents().len != before: return false
  let (s, ks) = x.r.sessionOf("alice")
  let r = xmrConfirmByHand(s, ks, xmrFor, x.seamOf("alice", cmNow), id, partName(bob), fromWallet = true)
  if r in ["submitted", "settling", "final"]: return false
  let remedy = (if opened.len > 0: "your wallet is on another network" else: "no Monero wallet is open")
  remedy in r and MoneroUnlockIntent in r and not x.partOf(id, "bob").confirmed

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    doAssert correct(k), "case " & $k & ": agreed on " & XmrChains[k div 4] & ", wallet open on " &
                         (if Opens[k mod 4].len > 0: Opens[k mod 4] else: "nothing") & " — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
