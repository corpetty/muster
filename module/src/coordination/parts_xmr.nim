## A part paid in XMR and confirmed by the creditor's own wallet (exo-dcc.5, ADR-018): the
## PartSeam a monero.split settles through.
##
## Muster never sends Monero. Each debtor pays from any wallet of theirs (Basecamp's, Cake,
## Feather) through a monero: link derived from the agreed effect (xmr_request.nim), so this
## seam's send refuses. What it does is the creditor's half: their own wallet, through
## monero_wallet_backend, confirms a part when its history shows an incoming transfer —
##   * direction "in", not failed;
##   * on payTo's subaddress (its index in the creditor's own receive_info, and that index
##     alone: a row spread over several subaddresses carries their sum);
##   * of exactly the share in atomic units — or, for a part alone at its subaddress (every
##     request and send; a split whose debtors share one payTo is told apart by amount, so
##     never), transfers there that together come to exactly the share, each at that depth:
##     a payer who sent too little tops it up (the part's reference is then every one of
##     them, comma-joined);
##   * at least the depth the request names (the payee chooses it; 10, Monero's default
##     spendable age, when it names none);
##   * from a wallet that is open, on the agreed chain's network, and not view-only;
##   * and not already used to confirm another part in the room (one reference settles one
##     part; the reference is the transfer's txid).
## A debtor's report — with or without a txid — never decides: the history does (s3). A
## read that is busy or did not answer is UNREAD: the part stays pending, never paid and
## never failed, and nothing is published. The chain itself shows no payer, payee or
## amount; the link between a transfer and the room lives only in the room.

import std/[algorithm, sets, strutils, tables]
import ../log/log
import ../drivers/driver
import ../intents/materialization   # PartTransfer
import ../monero/address
import ../wallet/monero_backend
import ./intents
import ./intent_events              # effectFromJson
import ./parts

type
  XmrVerdict* = enum
    xvConfirmed = "confirmed"   ## the read shows the part paid exactly: confirm it
    xvPending = "pending"       ## not (yet) shown: a later read may — never paid, never failed
    xvRefused = "refused"       ## this wallet cannot confirm this part (another network, view-only, not its payTo)
  XmrMatch* = object
    verdict*: XmrVerdict
    reference*: string          ## the txid that confirms it (xvConfirmed)
    detail*: string
    seen*: bool                 ## xvPending: the share is at payTo, below depth
    confirmations*: int64       ## …with this many confirmations, as the history row says (0–9)
    received*: string           ## a part alone at its subaddress: atomic units of every unclaimed
                                ## incoming transfer there, at any depth ("" when none, or shared)

  MoneroPartSeam* = ref object of PartSeam
    chain*: string              ## CAIP-2, "monero:<genesis prefix>"
    backend*: MoneroBackend     ## THIS member's own wallet, through monero_wallet_backend
    mode*: CallMode             ## cmPump on the intents tick, cmNow for a person's confirm
    shared*: HashSet[string]    ## payTo addresses more than one part in the room is paid at
                                ## (observe): a part there is matched by its exact amount only

proc newMoneroPartSeam*(chain: string, backend: MoneroBackend, mode = cmPump): MoneroPartSeam =
  MoneroPartSeam(chain: chain, backend: backend, mode: mode)

proc isTxid*(s: string): bool =
  ## A Monero transaction id as wallets show it: 32 bytes, 64 hex digits.
  s.len == 64 and s.allCharsInSet(HexDigits)

proc atomic(s: string): tuple[ok: bool, n: uint64] =
  ## A history row's amount, in atomic units; an unreadable one counts for nothing.
  if s.len == 0 or s.len > 20 or not s.allCharsInSet(Digits): return (false, 0'u64)
  try: (true, parseBiggestUInt(s).uint64) except ValueError: (false, 0'u64)

proc matchXmrPayment*(t: PartTransfer, status: WalletStatus, info: ReceiveInfo, hist: History,
                      claimed: HashSet[string], alone = false): XmrMatch =
  ## The decision, pure: whether the creditor's own reads show `t` received. Every rule in
  ## the module comment, in order; the first that fails says why. `alone`: no other part in
  ## the room is paid at `t.to`, so every transfer there is this part's, and they may add up.
  if not t.ok: return XmrMatch(verdict: xvRefused, detail: t.error)
  if t.asset != "XMR": return XmrMatch(verdict: xvRefused, detail: "a Monero part is paid in XMR, not " & t.asset)
  let why = walletRefusal(status, t.chain)
  if why.len > 0:
    # an unanswered read is not yet known; anything else is this wallet's refusal to confirm
    let v = (if why.startsWith("wallet-unread") or why.startsWith("wallet-busy"): xvPending else: xvRefused)
    return XmrMatch(verdict: v, detail: why)
  let a = acceptablePayTo(t.to, t.chain)
  if not a.ok: return XmrMatch(verdict: xvRefused, detail: "payTo: " & a.reason)
  case info.read
  of rsAnswered: discard
  else: return XmrMatch(verdict: xvPending, detail: info.detail)
  let idx = info.indexOf(t.to)
  if idx < 0:
    return XmrMatch(verdict: xvRefused,
                    detail: "payto-not-mine: your open wallet does not list " & t.to[0 ..< min(t.to.len, 12)] &
                            "…, the address this request is paid at")
  case hist.read
  of rsAnswered: discard
  else: return XmrMatch(verdict: xvPending, detail: hist.detail)
  let need = (if t.confirmations > 0: int64(t.confirmations) else: int64(XmrConfirmDepth))
  var nearest = ""
  var seen = false
  var depth = 0'i64
  for r in hist.rows:
    if r.direction != "in" or r.failed: continue
    if r.account != 0 or r.subaddrIndex != @[idx]: continue
    if r.amount != t.amount:
      if nearest.len == 0: nearest = "a transfer of " & (if r.amount.len > 0: r.amount else: "an unreadable amount") &
                                     " atomic units arrived; the share is " & t.amount
      continue
    if not isTxid(r.txid): continue
    if r.txid.toLowerAscii() in claimed:
      if nearest.len == 0: nearest = "the transfer " & r.txid[0 ..< 12] & "… already settled another part"
      continue
    if r.pending or r.confirmations < need:
      # what the row says, held below depth (a pending row is 0 deep); the deepest seen wins
      let c = (if r.pending: 0'i64 else: min(max(0'i64, r.confirmations), need - 1))
      if not seen or c > depth:
        depth = c
        nearest = "a transfer of exactly the share arrived (" & r.txid[0 ..< 12] & "…), " & $c &
                  " of " & $need & " confirmations"
      seen = true
      continue
    return XmrMatch(verdict: xvConfirmed, reference: r.txid.toLowerAscii())
  var received = ""
  if alone:
    # every unclaimed transfer at payTo is this part's: they settle it when they come to
    # exactly the share, each at depth — a payer who sent too little topped it up
    let share = atomic(t.amount)
    var total = 0'u64
    var txids: seq[string]
    var least = need
    var overflow = false
    for r in hist.rows:
      if r.direction != "in" or r.failed: continue
      if r.account != 0 or r.subaddrIndex != @[idx]: continue
      if not isTxid(r.txid) or r.txid.toLowerAscii() in claimed: continue
      let a = atomic(r.amount)
      if not a.ok: continue
      if total > high(uint64) - a.n: (overflow = true; break)
      total += a.n
      if r.txid.toLowerAscii() notin txids: txids.add r.txid.toLowerAscii()
      least = min(least, (if r.pending: 0'i64 else: max(0'i64, r.confirmations)))
    if txids.len > 0 and not overflow: received = $total
    if share.ok and not overflow and txids.len > 1 and total == share.n:
      if least >= need:
        txids.sort()
        return XmrMatch(verdict: xvConfirmed, reference: txids.join(","), received: received)
      return XmrMatch(verdict: xvPending, seen: true, confirmations: min(least, need - 1), received: received,
                      detail: $txids.len & " transfers came to exactly the share; the shallowest is " &
                              $min(least, need - 1) & " of " & $need & " confirmations")
    if not seen and received.len > 0 and share.ok:
      nearest = (if total < share.n:
                   "received " & received & " of the share's " & t.amount & " atomic units; " &
                   $(share.n - total) & " more to come"
                 else:
                   "received " & received & " atomic units, more than the share's " & t.amount &
                   ": they never come to exactly the share")
  XmrMatch(verdict: xvPending, seen: seen, confirmations: depth, received: received,
           detail: (if nearest.len > 0: nearest
                    else: "no incoming transfer of exactly " & t.amount & " atomic units at subaddress " & $idx &
                          " yet — the creditor's own wallet history is what confirms it"))

proc readMatch*(s: MoneroPartSeam, t: PartTransfer, claimed: HashSet[string]): XmrMatch =
  ## The creditor's own reads, in the order the decision needs them — none further once
  ## one cannot be used: wallet_status, receive_info, history.
  if t.chain != s.chain:
    return XmrMatch(verdict: xvRefused, detail: "this seam reads " & s.chain & "; the part settles on " & t.chain)
  let st = s.backend.walletStatus(s.mode)
  if walletRefusal(st, t.chain).len > 0:
    return matchXmrPayment(t, st, ReceiveInfo(read: rsUnread), History(read: rsUnread), claimed)
  let info = s.backend.receiveInfo(s.mode)
  if info.read != rsAnswered or info.indexOf(t.to) < 0:
    return matchXmrPayment(t, st, info, History(read: rsUnread), claimed)
  let hist = s.backend.history(s.mode)
  # a history names no wallet: the wallet open after it was read must be the one open
  # before, or what it shows is not known to be this wallet's (s7)
  let after = s.backend.walletStatus(s.mode)
  if after.read != rsAnswered or after.wallet != st.wallet or after.network != st.network or
     after.state != st.state:
    let m = matchXmrPayment(t, after, info, History(read: rsUnread), claimed)
    if m.verdict != xvPending: return m
    return XmrMatch(verdict: xvPending, detail: "the open wallet changed while its history was read: read again")
  matchXmrPayment(t, st, info, hist, claimed, alone = t.to notin s.shared)

proc sharedPayTos*(events: seq[Event], driverFor: DriverFor): HashSet[string] =
  ## The XMR payTo addresses more than one part in this room is paid at, in any intent and
  ## any state: a split whose debtors pay one subaddress, told apart by their amounts. A part
  ## anywhere else is alone at its subaddress (a request's or a send's is never reused).
  var count = initCountTable[string]()
  for v in reduceIntentViews(events, driverFor):
    if v.parts.len == 0: continue
    let drv = driverFor(v.policy)
    var effect: Effect
    try: effect = effectFromJson(v.effectJson) except CatchableError: continue
    for p in v.parts:
      let t = drv.partTransfer(effect, p.part)
      if t.ok and t.asset == "XMR" and t.to.len > 0: count.inc t.to
  for to, n in count:
    if n > 1: result.incl to

method observe*(s: MoneroPartSeam, events: seq[Event], driverFor: DriverFor) =
  s.shared = sharedPayTos(events, driverFor)

method sendPart*(s: MoneroPartSeam, t: PartTransfer): tuple[ok: bool, tx, detail: string] =
  (false, "", "muster never sends Monero: pay your share from your own wallet with the request's monero: link, " &
              "then say you paid")
method partLanded*(s: MoneroPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  (false, "muster never sends Monero; the creditor's own wallet confirms the payment")
method checkReceived*(s: MoneroPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  (false, "a Monero payment is confirmed only by the creditor's own wallet history, never by a txid alone")
method confirmsUnreported*(s: MoneroPartSeam): bool = true

method matchReceived*(s: MoneroPartSeam, t: PartTransfer, reported: string,
                      claimed: HashSet[string]): tuple[ok: bool, reference, detail: string] =
  ## MY wallet's history, never the reported txid: a transfer of exactly the share at
  ## payTo's subaddress, 10 deep, not claimed for another part. `reported` is the payer's
  ## claim; it is not what proves receipt.
  let m = s.readMatch(t, claimed)
  case m.verdict
  of xvConfirmed: (true, m.reference, "")
  of xvPending: (false, "", "pending: " & m.detail)
  of xvRefused: (false, "", m.detail)
