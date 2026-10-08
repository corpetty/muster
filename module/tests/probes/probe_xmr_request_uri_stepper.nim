## derived-exo-dcc.5 s1: the payment is derived from the agreed request — the monero: link a
## debtor is shown carries exactly the agreed payTo and that debtor's agreed share, in
## atomic units, never typed by hand; any other address or amount is a different link, and
## nothing else (the memo) changes it.
##
## STEPPER: state = one case of network {mainnet, stagenet, testnet} x payTo kind {the
## creditor's standard address, a subaddress her wallet mints} x share {1 atomic unit, 1 XMR,
## 1.5 XMR, 2^64 - 2} x debtor {Bob, Carol} x memo {two}: 96 cases, chained case -> case+1.
## Each case runs the REAL request path (coordination/xmr_request.nim, what the module hosts)
## over fake Monero wallets: Alice's wallet gives payTo, Alice proposes (Bob owes the share,
## Carol the share + 1: one subaddress takes both, so they differ), Bob and Carol agree, and
## the case's debtor's client shows their link (xmrPaymentLink). The rule, stated alone:
##   * before everyone agreed there is no link;
##   * the link is makePaymentUri(chain, the agreed payTo, that debtor's share) with no
##     description — on the debtor's own client and on every other member's — and it reads
##     back (parsePaymentUri) as exactly that address and amount, no description;
##   * payTo changed to another address, or the share by one atomic unit either way, gives
##     a different link; the other debtor's link is a different link; the memo is nowhere
##     in it, so both memos give the same link.
## Run by hand (no argv), it checks all 96 with doAssert.

import std/[json, strutils]
import ./xmr_room
import ./oracle_emit

const Shares = [1'u64, 1_000_000_000_000'u64, 1_500_000_000_000'u64, 18446744073709551614'u64]
const Memos = ["rent for March", "the cabin & 100% of fuel"]
const N = 96

proc decode(k: int): tuple[net, kind, share, debtor, memo: int] =
  (k div 32, (k mod 32) div 16, (k mod 16) div 4, (k mod 4) div 2, k mod 2)

proc correct(k: int): bool =
  let (n, kind, si, di, mi) = decode(k)
  let chain = XmrChains[n]
  var x = newXmrRoom("/muster/1/xmr-uri-" & $k & "/proto", chain)
  let w = x.wallet("alice")
  let payTo = (if kind == 0: w.primary else: xmrMintPayTo(w, chain, "muster:probe").address)
  if payTo.len == 0: return false
  let share = Shares[si]
  let shares = @[(bob, $share), (carol, $(share + 1))]
  let id = x.propose("alice", x.requestJson(payTo, shares, Memos[mi]))
  if not id.startsWith("0x"): return false
  let debtor = (if di == 0: "bob" else: "carol")
  let mine = (if di == 0: share else: share + 1)
  let theirs = (if di == 0: share + 1 else: share)
  # no link before every party agreed
  x.r.sync()
  if x.linkOf(debtor, id, debtor).ok: return false
  if x.agree("bob", id) notin ["collecting", "executable"]: return false
  if x.agree("carol", id) != "executable": return false
  let expected = makePaymentUri(chain, payTo, mine)
  if not expected.ok: return false
  let link = x.linkOf(debtor, id, debtor)
  if not link.ok or link.uri != expected.uri: return false
  if link.amount != $mine or link.payTo != payTo or link.chain != chain: return false
  # every member's client shows the same link for that part
  for viewer in ["alice", "bob", "carol", "dave"]:
    if x.linkOf(viewer, id, debtor).uri != link.uri: return false
  # it reads back as exactly the agreed address and amount, and nothing else
  let back = parsePaymentUri(link.uri, chain)
  if not back.ok or back.address != payTo or back.amount != mine or back.description.len > 0 or
     back.recipientName.len > 0 or back.paymentId.len > 0 or back.unknown.len > 0: return false
  # another address, or the share moved by one atomic unit, is a different link
  let other = walletAddress("wallet-dave", netOf(chain), 1)
  if makePaymentUri(chain, other, mine).uri == link.uri: return false
  if makePaymentUri(chain, payTo, mine + 1).uri == link.uri: return false
  if mine > 1 and makePaymentUri(chain, payTo, mine - 1).uri == link.uri: return false
  # the other debtor's link is theirs, not this one
  let otherDebtor = (if di == 0: "carol" else: "bob")
  let ol = x.linkOf(debtor, id, otherDebtor)
  if not ol.ok or ol.uri == link.uri or ol.uri != makePaymentUri(chain, payTo, theirs).uri: return false
  # the memo never reaches the link (it stays in the room)
  for m in Memos:
    if m in link.uri or urlEncode(m) in link.uri: return false
  if "tx_description" in link.uri or "recipient_name" in link.uri: return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (n, kind, si, di, mi) = decode(k)
    doAssert correct(k), "case " & $k & ": " & XmrChains[n] & ", payTo " & (if kind == 0: "standard" else: "subaddress") &
                         ", share " & $Shares[si] & ", debtor " & $di & ", memo " & $mi & " — the link is not the agreed one"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
