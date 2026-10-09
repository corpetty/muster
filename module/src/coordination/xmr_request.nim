## The XMR payment request, live (exo-dcc.5, ADR-018; docs/labbook/xmr-payment-request.md):
## the steps a hosted call takes for a monero.split, here so they can be driven in-process
## by the tests and the spec's probes exactly as the module drives them. The module's
## handlers (nim-lib/muster_module.nim) are plumbing over these.
##
##   mint      xmrMintPayTo       the creditor's own wallet mints a fresh subaddress
##                                (create_subaddress, no role) for the request
##   propose   xmrPropose         the creditor proposes; their client first checks the
##                                wallet lists payTo, on the agreed network (s2)
##   agree     xmrAgree           each party's room-key agreement; the creditor's client
##                                refuses a payTo its own wallet does not list (s2)
##   pay       xmrPaymentLink     each debtor's monero: link — derived from the AGREED
##                                effect alone, never typed (s1); the debtor pays from any
##                                wallet of theirs; muster sends nothing
##             xmrReportPaid      "I paid": the debtor's author-signed report, which never
##                                confirms anything by itself (s3, s5)
##   confirm   xmrConfirmPump     the creditor's own wallet history confirms each part
##                                (parts_xmr.nim, s3, s4, s7)
## Every wallet call goes through wallet/monero_backend's closed call set (s6).

import std/[json, strutils, sequtils, tables, times, options]
import ../log/log
import ../crypto/keystore
import ../crypto/binding            # LinkContext
import ../hashing/sha256
import ../intents/materialization
import ../drivers/driver
import ../drivers/kinds
import ../drivers/split
import ../monero/address
import ../wallet/monero_backend
import ./session
import ./authorship
import ./intents
import ./intent_events
import ./live
import ./parts
import ./parts_xmr

export monero_backend, parts_xmr

const
  XmrAsset* = "XMR"
  XmrKind* = "monero-split"

proc xmrPolicy*(chain: string): string = XmrKind & "@" & chain

proc isXmrPolicy*(policy: string): bool = kindOf(policy) == XmrKind

proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc xmrRequestLabel*(chain, total, memo: string, nonce: uint64): string =
  ## The label a request's subaddress is minted under: "muster:req-<16 hex>". Not the
  ## intent id: the id commits to payTo, which is the very address being minted.
  var b: seq[byte]
  for c in chain & "|" & total & "|" & memo & "|" & $nonce: b.add byte(c)
  "muster:req-" & hx(sha256(b))[0 ..< 16]

# ── payTo: minted by the creditor's own wallet, and vouched for only by it ──────────
proc xmrMintPayTo*(b: MoneroBackend, chain, label: string): tuple[ok: bool, address, why: string] =
  ## A fresh subaddress of the creditor's open wallet, for a request on `chain`: the wallet
  ## must be open on the chain's network and able to spend what it receives; the address it
  ## mints must be one this chain accepts.
  let why = walletRefusal(b.walletStatus(cmNow), chain)
  if why.len > 0: return (false, "", why)
  let m = b.createSubaddress(label)
  if not m.ok: return (false, "", "wallet-unread: " & m.detail)
  let a = acceptablePayTo(m.address, chain)
  if not a.ok: return (false, "", "payto-invalid: the wallet minted an address this request cannot be paid at: " & a.reason)
  (true, m.address, "")

proc payToRefusal*(payTo, chain: string): string =
  ## "" when `payTo` is an address a request on `chain` can be paid at; otherwise a code:
  ## payto-other-network | payto-integrated | payto-invalid, with why.
  let a = acceptablePayTo(payTo, chain)
  if a.ok: return ""
  case a.refusal
  of mrWrongNetwork: "payto-other-network: " & a.reason
  of mrIntegrated: "payto-integrated: " & a.reason
  else: "payto-invalid: " & a.reason

proc xmrCreditorRefusal*(b: MoneroBackend, effect: Effect, me: string): string =
  ## Before THIS member proposes or agrees to a Monero request: "" unless they are its
  ## creditor and their own wallet cannot vouch that payTo is theirs — then why. Their
  ## agreement is their word that payTo is theirs (exo-770): their client never gives it
  ## for an address on another network, an integrated address, or one their open wallet
  ## does not list (receive_info).
  var sp: Split
  try: sp = splitOf(effect)
  except ValueError: return ""
  if familyOfChain(sp.chain) != MoneroSplitFamily: return ""
  if sp.creditor != me.toLowerAscii().replace("0x", ""): return ""
  let bad = payToRefusal(sp.payTo, sp.chain)
  if bad.len > 0: return bad
  let why = walletRefusal(b.walletStatus(cmNow), sp.chain)
  if why.len > 0: return why
  let info = b.receiveInfo(cmNow)
  if info.read != rsAnswered: return "wallet-unread: " & info.detail
  if info.indexOf(sp.payTo) < 0:
    return "payto-not-mine: your open wallet does not list the address this request would be paid at"
  ""

proc xmrPropose*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, b: MoneroBackend,
                 chain, effectJson: string, nowSec: int64, msgSeq: uint64,
                 ttlSec = DefaultIntentTtl): string =
  ## Propose a Monero request under monero-split@<chain>. The creditor proposing their own
  ## request is their agreement, so their client checks payTo first (s2). Returns the
  ## intent id, or a refusal with nothing published.
  let effect = effectFromJson(effectJson)
  let why = xmrCreditorRefusal(b, effect, myIdentity(ks))
  if why.len > 0: return why
  var payTo = ""
  try: payTo = splitOf(effect).payTo
  except ValueError: discard
  liveProposeIntent(s, ks, driverFor, xmrPolicy(chain), effectJson, nowSec, msgSeq,
                    account = chain & ":" & payTo, ttlSec = ttlSec)

proc xmrAgree*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, b: MoneroBackend,
               intentId: string, ctx: LinkContext, nowSec: uint64): string =
  ## Agree to a Monero request: a debtor to their share, the creditor that payTo is theirs —
  ## refused, with nothing published, when the creditor's own wallet does not list it (s2).
  s.poll()
  let events = s.roomEvents()
  let ej = effectJsonOf(events, intentId)
  if ej.len == 0: return "unknown-intent"
  let why = xmrCreditorRefusal(b, effectFromJson(ej), myIdentity(ks))
  if why.len > 0: return why
  liveContribute(s, ks, driverFor, intentId, "", "", ctx, nowSec)

# ── the payer's half: a link, and "I paid" ─────────────────────────────────────────
type XmrLink* = object
  ok*: bool
  why*: string        ## why there is no link: not-agreed, not-a-monero-request, the driver's refusal…
  part*: string       ## the debtor, as the driver names the part ("ed:<hex>")
  uri*: string        ## monero:<payTo>?tx_amount=<share in XMR> — wallet2's make_uri
  amount*: string     ## the share, atomic units
  payTo*: string
  chain*: string

proc linkFor(drv: Driver, effect: Effect, part: string): XmrLink =
  let t = drv.partTransfer(effect, part)
  if not t.ok: return XmrLink(ok: false, part: part, why: t.error)
  # nothing but the agreed transfer reaches the link: no memo, no name (they stay in the room)
  let u = makePaymentUri(t.chain, t.to, t.amount)
  if not u.ok: return XmrLink(ok: false, part: part, why: u.reason)
  XmrLink(ok: true, part: part, uri: u.uri, amount: t.amount, payTo: t.to, chain: t.chain)

proc xmrLinks*(events: seq[Event], driverFor: DriverFor, intentId: string): seq[XmrLink] =
  ## Every debtor's link, in the driver's part order — derived from the effect in the LOG
  ## for this intent id (the bytes every party signed), and only once it is agreed: a link
  ## is shown for a request its creditor has vouched for, never before.
  let ej = effectJsonOf(events, intentId)
  if ej.len == 0: return
  let policy = intentPolicyOf(events, intentId)
  if not isXmrPolicy(policy): return
  let drv = driverFor(policy)
  let effect = effectFromJson(ej)
  let parts = drv.settlementParts(effect)
  let st = intentState(events, driverFor, intentId)
  for p in parts:
    if st notin ["executable", "submitted", "settling", "final"]:
      result.add XmrLink(ok: false, part: p, why: "not-agreed: every party named must agree before anyone pays")
    else:
      result.add linkFor(drv, effect, p)

proc xmrPaymentLink*(events: seq[Event], driverFor: DriverFor, intentId, part: string): XmrLink =
  ## The link `part`'s debtor is shown.
  for l in xmrLinks(events, driverFor, intentId):
    if l.part == part: return l
  XmrLink(ok: false, part: part, why: "not a part of a Monero request in this room")

proc xmrPayable*(events: seq[Event], driverFor: DriverFor, intentId: string): bool =
  ## Whether this client treats the request as payable: agreed, and every part's link
  ## derivable (a valid payTo for the chain, every share a Monero amount).
  let ls = xmrLinks(events, driverFor, intentId)
  ls.len > 0 and ls.allIt(it.ok)

proc xmrReportPaid*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId, txid: string): string =
  ## "I paid": THIS debtor's author-signed settled report for their part, carrying the txid
  ## they give ("" = none). It is their claim: it moves the request to submitted and never
  ## confirms a part — only the creditor's own wallet does (s3, s5). Returns the intent's
  ## state, or a refusal with nothing published: unknown-intent | not-a-monero-request |
  ## not-a-party | not-agreed | already-settled | bad-txid.
  s.poll()
  let events = s.roomEvents()
  let ej = effectJsonOf(events, intentId)
  if ej.len == 0: return "unknown-intent"
  let policy = intentPolicyOf(events, intentId)
  if not isXmrPolicy(policy): return "not-a-monero-request"
  let tx = txid.strip().toLowerAscii()
  if tx.len > 0 and not isTxid(tx): return "bad-txid"
  let drv = driverFor(policy)
  let effect = effectFromJson(ej)
  let me = myIdentity(ks)
  var mine = ""
  for p in drv.settlementParts(effect):
    if drv.partAuthor(effect, p, "settled").toLowerAscii() == me: mine = p
  if mine.len == 0: return "not-a-party"
  var found = false
  var v: IntentView
  for w in reduceIntentViews(events, driverFor):
    if w.id == intentId: (found = true; v = w)
  if not found or v.state notin ["executable", "submitted", "settling"]:
    return (if found and v.state == "final": "already-settled" else: "not-agreed")
  for pv in v.parts:
    if pv.part == mine and pv.settled: return "already-settled"
  s.publishAuthored(ks, partEvent(intentId, mine, "settled", me, tx))
  intentState(s.roomEvents(), driverFor, intentId)

# ── the creditor's half ───────────────────────────────────────────────────────────
proc xmrConfirmPump*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor,
                     seam: MoneroPartSeam): seq[string] =
  ## Every part of an agreed Monero request this member is owed, confirmed when their own
  ## wallet's history shows it — reported or not (the report never decides).
  liveConfirmParts(s, ks, driverFor, seam)

proc xmrConfirmByHand*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: MoneroPartSeam,
                       intentId, part: string, fromWallet: bool): string =
  ## The creditor's own confirm of one part: from their wallet's history now (`fromWallet`),
  ## or — "Mark received" — their word that it arrived, with no reference, shown as such.
  liveConfirmPart(s, ks, driverFor, intentId, part, seam, "", fromRead = fromWallet)

proc xmrShareBody*(chain, address: string): JsonNode =
  ## The address-share card a member posts so a request can be proposed on their behalf.
  %*{"kind": "address-share", "asset": XmrAsset, "chain": chain, "address": address, "form": 1}

# ── what the room shows around a request (exo-dcc.20) ───────────────────────────────
const XmrShareLabel* = "muster:share"

proc xmrShareAddress*(s: CoordinationSession, ks: Keystore, b: MoneroBackend, chain: string,
                      msgSeq: uint64, nowSec = int64(epochTime())): tuple[ok: bool, address, why: string] =
  ## "Share my Monero address": a FRESH subaddress THIS member's own open wallet mints
  ## (create_subaddress, labelled muster:share), held to the chain's network and payTo
  ## rules (xmrMintPayTo, monero/address.nim), posted as their author-signed address-share
  ## for `chain`. What a request proposed on their behalf pays them at — and their client
  ## still checks their wallet lists it before they agree (s2). Refused, with nothing
  ## minted or posted, when the wallet cannot vouch (no-wallet, wallet-other-network,
  ## wallet-watch-only, wallet-unread, wallet-busy) or `chain` is not a Monero chain.
  if networkOfChain(chain).isNone:
    return (false, "", "unknown-chain: not a Monero chain muster knows: " & chain)
  let m = xmrMintPayTo(b, chain, XmrShareLabel)
  if not m.ok: return (false, "", m.why)
  let (_, ev) = newMessageEvent("0x" & myIdentity(ks), nowSec, $xmrShareBody(chain, m.address), msgSeq)
  s.publishAuthored(ks, ev)
  (true, m.address, "")

type XmrUnlockTarget* = object
  ## Which wallet a remedy asks Monero Wallet to open: monero.wallet.unlock takes the
  ## wallet's registry name, and answers bad_request without one.
  read*: ReadState            ## rsAnswered once known; else the list did not answer — nothing named
  detail*: string
  wallet*: string             ## the one to name ("" = none to name)
  wallets*: seq[string]       ## several could be the one: the person picks
  none*: bool                 ## no wallet on the network at all: create or restore one (monero.accounts.manage)

proc xmrUnlockTarget*(b: MoneroBackend, chain: string, mode = cmNow): XmrUnlockTarget =
  ## The wallet to unlock for a request on `chain`: the open one when it is on the chain's
  ## network and can spend; else, from list_wallets, the one registered on that network
  ## that can spend (a file never opened, network "", only when none is known to be on
  ## it); several, all of them, for the person to pick; none, `none`. A list that did not
  ## answer names nothing and never says "none": it is not known. Reads wallet_status and
  ## list_wallets only — never a request's own step (s6).
  let want = networkOfChain(chain)
  if want.isNone: return XmrUnlockTarget(read: rsUnread, detail: "not a Monero chain: " & chain)
  let net = $want.get
  let st = b.walletStatus(mode)
  if st.read == rsAnswered and st.wallet.len > 0 and st.network == net and not st.watchOnly and
     st.state in ["ready", "syncing", "opening"]:
    return XmrUnlockTarget(read: rsAnswered, wallet: st.wallet)
  let l = b.listWallets(mode)
  if l.read != rsAnswered: return XmrUnlockTarget(read: l.read, detail: l.detail)
  var exact, unknown: seq[string]
  for w in l.wallets:
    if w.viewOnly: continue
    if w.network == net: exact.add w.name
    elif w.network.len == 0: unknown.add w.name
  let c = (if exact.len > 0: exact else: unknown)
  if c.len == 1: XmrUnlockTarget(read: rsAnswered, wallet: c[0])
  elif c.len > 1: XmrUnlockTarget(read: rsAnswered, wallets: c)
  else: XmrUnlockTarget(read: rsAnswered, none: true,
                        detail: "no " & net & " wallet that can spend is registered in Monero Wallet")

proc unlockJson*(t: XmrUnlockTarget): JsonNode =
  ## What a hosted remedy carries beside request: "monero.wallet.unlock": the wallet to
  ## name, the ones to pick from, and whether there is none (then monero.accounts.manage).
  %*{"wallet": t.wallet, "wallets": t.wallets, "noWallet": t.none}

proc xmrSeenConfirmations*(events: seq[Event], driverFor: DriverFor, seam: MoneroPartSeam,
                           me: string): Table[string, int] =
  ## "<intent>/<part>" → confirmations (0–9) of the transfer of exactly that share THIS
  ## creditor's own wallet history shows at payTo, below the 10 a part is confirmed at —
  ## for every unconfirmed part of an agreed Monero request `me` confirms. Only what a
  ## read showed: a busy or unanswered read, another network, or no such transfer adds
  ## nothing (never an invented count). On a debtor's client it is empty.
  let claimed = confirmedRefs(events, driverFor)
  for v in reduceIntentViews(events, driverFor):
    if not isXmrPolicy(v.policy) or v.state notin ["executable", "submitted", "settling"]: continue
    let drv = driverFor(v.policy)
    let effect = effectFromJson(v.effectJson)
    for p in v.parts:
      if p.confirmed: continue
      if drv.partAuthor(effect, p.part, "confirmed").toLowerAscii() != me.toLowerAscii(): continue
      let t = drv.partTransfer(effect, p.part)
      if not t.ok: continue
      let m = seam.readMatch(t, claimed)
      if m.verdict == xvPending and m.seen: result[v.id & "/" & p.part] = int(m.confirmations)

proc xmrOwedOn*(events: seq[Event], driverFor: DriverFor, me: string): seq[string] =
  ## The Monero chains `me` is owed on: every request not yet final (nor dropped or
  ## expired) that names them as its creditor. Their own wallet vouches for and confirms
  ## those; on any other chain they at most pay, from any wallet.
  let mine = me.toLowerAscii().replace("0x", "")
  for v in reduceIntentViews(events, driverFor):
    if not isXmrPolicy(v.policy) or v.state in ["final", "dropped", "expired"]: continue
    try:
      let sp = splitOf(effectFromJson(v.effectJson))
      if sp.creditor == mine and sp.chain notin result: result.add sp.chain
    except ValueError: discard
