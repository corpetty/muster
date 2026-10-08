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
##   * of exactly the share in atomic units;
##   * at least 10 confirmations (Monero's default spendable age);
##   * from a wallet that is open, on the agreed chain's network, and not view-only;
##   * and not already used to confirm another part in the room (one reference settles one
##     part; the reference is the transfer's txid).
## A debtor's report — with or without a txid — never decides: the history does (s3). A
## read that is busy or did not answer is UNREAD: the part stays pending, never paid and
## never failed, and nothing is published. The chain itself shows no payer, payee or
## amount; the link between a transfer and the room lives only in the room.

import std/[sets, strutils]
import ../intents/materialization   # PartTransfer
import ../monero/address
import ../wallet/monero_backend
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

  MoneroPartSeam* = ref object of PartSeam
    chain*: string              ## CAIP-2, "monero:<genesis prefix>"
    backend*: MoneroBackend     ## THIS member's own wallet, through monero_wallet_backend
    mode*: CallMode             ## cmPump on the intents tick, cmNow for a person's confirm

proc newMoneroPartSeam*(chain: string, backend: MoneroBackend, mode = cmPump): MoneroPartSeam =
  MoneroPartSeam(chain: chain, backend: backend, mode: mode)

proc isTxid*(s: string): bool =
  ## A Monero transaction id as wallets show it: 32 bytes, 64 hex digits.
  s.len == 64 and s.allCharsInSet(HexDigits)

proc matchXmrPayment*(t: PartTransfer, status: WalletStatus, info: ReceiveInfo, hist: History,
                      claimed: HashSet[string]): XmrMatch =
  ## The decision, pure: whether the creditor's own reads show `t` received. Every rule in
  ## the module comment, in order; the first that fails says why.
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
  var nearest = ""
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
    if r.pending or r.confirmations < XmrConfirmDepth:
      nearest = "a transfer of exactly the share arrived (" & r.txid[0 ..< 12] & "…), " & $max(0'i64, r.confirmations) &
                " of " & $XmrConfirmDepth & " confirmations"
      continue
    return XmrMatch(verdict: xvConfirmed, reference: r.txid.toLowerAscii())
  XmrMatch(verdict: xvPending,
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
  matchXmrPayment(t, st, info, s.backend.history(s.mode), claimed)

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
