## A shared fixture for the XMR payment request's tests and spec probes (derived-exo-dcc.5):
## split_room's room of four — Alice, who is owed (the creditor), Bob and Carol, who owe her,
## Dave, whom the request does not name — over the local transport, each with their own
## fake Monero wallet (fake_monero.nim), and the split driver resolving
## monero-split@<chain> on mainnet, stagenet and testnet. Every step goes through
## coordination/xmr_request.nim, the path the hosted module takes. Not a probe itself.

import std/[json, strutils, sequtils]
import ../../src/crypto/binding
import ../../src/intents/materialization
import ../../src/coordination/intent_events
import ../../src/coordination/xmr_request
import ../../src/coordination/parts
import ./split_room
import ./fake_monero
export split_room, fake_monero, xmr_request, parts, binding, materialization, intent_events

let XmrMain* = caip2Of(xmrMainnet)
let XmrStage* = caip2Of(xmrStagenet)
let XmrTest* = caip2Of(xmrTestnet)
let XmrChains* = @[XmrMain, XmrStage, XmrTest]

let xmrFor*: DriverFor = proc(policy: string): Driver =
  let (k, chain) = splitPolicy(policy)
  if k == "monero-split" and chain in XmrChains: newSplitDriver(MoneroSplitFamily, chain, roster)
  else: newUnsupportedDriver(policy)

type XmrRoom* = object
  r*: Room4
  chain*: string
  wallets*: array[4, FakeMoneroBackend]   ## alice, bob, carol, dave — each their own
  seqNo*: uint64

proc whoIndex(who: string): int =
  case who
  of "alice": 0
  of "bob": 1
  of "carol": 2
  else: 3

proc newXmrRoom*(topic, chain: string): XmrRoom =
  result = XmrRoom(r: newRoom4(topic), chain: chain)
  let net = $netOf(chain)
  for i, n in ["alice", "bob", "carol", "dave"]:
    result.wallets[i] = newFakeMonero("wallet-" & n, net)

proc wallet*(x: XmrRoom, who: string): FakeMoneroBackend = x.wallets[whoIndex(who)]

proc ctxNow*(): LinkContext = LinkContext(account: "probe", slot: "0", expiry: Now + 86_400)

proc requestJson*(x: XmrRoom, payTo: string, shares: seq[(string, string)], memo = "rent",
                  creditor = alice): string =
  ## The effect a composer proposes: shares by identity, the total their sum (the creditor
  ## is not in it: a payment request).
  var ss: seq[SplitShare]
  var total = "0"
  for (who, amount) in shares:
    ss.add SplitShare(who: who, amount: amount)
  # canonical decimal sum, by digits (a share may be near 2^64)
  proc addDec(a, b: string): string =
    var i = a.len - 1
    var j = b.len - 1
    var carry = 0
    var r = ""
    while i >= 0 or j >= 0 or carry > 0:
      var d = carry
      if i >= 0: d += ord(a[i]) - ord('0')
      if j >= 0: d += ord(b[j]) - ord('0')
      r.insert($(d mod 10), 0)
      carry = d div 10
      dec i
      dec j
    r
  for (_, amount) in shares: total = addDec(total, amount)
  splitEffectJson(x.chain, "XMR", total, creditor, payTo, ss, memo)

proc propose*(x: var XmrRoom, who, effectJson: string): string =
  ## `who` proposes, through the hosted path (xmrPropose), checked by THEIR wallet.
  inc x.seqNo
  let (s, ks) = x.r.sessionOf(who)
  xmrPropose(s, ks, xmrFor, x.wallet(who), x.chain, effectJson, int64(Now), x.seqNo, Ttl)

proc agree*(x: XmrRoom, who, id: string): string =
  let (s, ks) = x.r.sessionOf(who)
  xmrAgree(s, ks, xmrFor, x.wallet(who), id, ctxNow(), Now)

proc linkOf*(x: XmrRoom, viewer, id, debtor: string): XmrLink =
  ## The link `viewer`'s client shows for `debtor`'s part.
  x.r.sync()
  let (s, _) = x.r.sessionOf(viewer)
  xmrPaymentLink(s.roomEvents(), xmrFor, id, partName(identityOf(debtor)))

proc reportPaid*(x: XmrRoom, who, id, txid: string): string =
  let (s, ks) = x.r.sessionOf(who)
  xmrReportPaid(s, ks, xmrFor, id, txid)

proc seamOf*(x: XmrRoom, who: string, mode = cmPump): MoneroPartSeam =
  newMoneroPartSeam(x.chain, x.wallet(who), mode)

proc pump*(x: XmrRoom, who = "alice"): seq[string] =
  ## `who`'s confirm pump, over their own wallet.
  x.r.sync()
  let (s, ks) = x.r.sessionOf(who)
  xmrConfirmPump(s, ks, xmrFor, x.seamOf(who))

proc stateOf*(x: XmrRoom, id: string, viewer = "alice"): string =
  x.r.sync()
  let (s, _) = x.r.sessionOf(viewer)
  intentState(s.roomEvents(), xmrFor, id)

proc partOf*(x: XmrRoom, id, debtor: string, viewer = "alice"): PartView =
  x.r.sync()
  let (s, _) = x.r.sessionOf(viewer)
  for v in reduceIntentViews(s.roomEvents(), xmrFor):
    if v.id == id:
      for p in v.parts:
        if p.part == partName(identityOf(debtor)): return p

proc agreedRequest*(x: var XmrRoom, shares: seq[(string, string)], memo = "rent"): tuple[id, payTo: string] =
  ## Alice mints a subaddress, proposes, and Bob and Carol (whoever the shares name) agree.
  let m = xmrMintPayTo(x.wallet("alice"), x.chain, "muster:test")
  doAssert m.ok, m.why
  let id = x.propose("alice", x.requestJson(m.address, shares, memo))
  doAssert id.startsWith("0x"), id
  x.r.sync()
  for (who, _) in shares:
    var name = ""
    for n in ["bob", "carol", "dave"]:
      if identityOf(n) == who: name = n
    let r = x.agree(name, id)
    doAssert r in ["collecting", "executable"], name & " agree: " & r
  (id, m.address)

proc subIndexOf*(x: XmrRoom, address: string): int =
  for s in x.wallet("alice").subs:
    if s.address == address: return s.index
  -1

export sequtils, strutils, json
