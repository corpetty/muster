## A part paid and received on the LEZ's PRIVATE rail (exo-a90.9; docs/design/split-the-bill.md
## §4.6, §4.7): the PartSeam the private split (lez.split) settles through.
##
## The payer's own LEZ wallet sends shielded → shielded, so the chain learns no payer, no
## payee and no amount — which is also why the creditor cannot look a payment up by its
## sender's reference. Instead the creditor's own wallet SCANS: a note that arrived at the
## split's payTo key node, of exactly one share's amount (a private split's shares all
## differ), not already claimed for another share. The reference the room records is a
## hash of the note's id — enough to claim it once, nothing that points at the note.

import std/[json, sets, strutils]
import ../crypto/keystore
import ../hashing/sha256
import ../intents/materialization   # PartTransfer
import ../wallet/[types, lez_core, lez_adapter]
import ./parts

type LezPartSeam* = ref object of PartSeam
  chain*: string            ## CAIP-2, "lez:<zone>"
  adapter*: LezAdapter      ## this member's own LEZ wallet
  ks*: Keystore
  payFrom*: Account         ## the account this member pays from; empty = the one note that covers the share
  lastRail*: TransferForm   ## the rail of the last payment sent (what the chain saw of it)

proc newLezPartSeam*(chain: string, adapter: LezAdapter, ks: Keystore, payFrom = Account()): LezPartSeam =
  LezPartSeam(chain: chain, adapter: adapter, ks: ks, payFrom: payFrom)

proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc noteRef*(noteId: string): string =
  ## What the room records for a received note: 16 bytes of sha256 of its id.
  var b: seq[byte]
  for c in noteId: b.add byte(c)
  "note:" & hx(sha256(b))[0 ..< 32]

proc decAtLeast(a, b: string): bool =
  ## a >= b for canonical decimal base units (u128 on the zone: no machine integer).
  var x = a
  var y = b
  while x.len > 1 and x[0] == '0': x = x[1 .. ^1]
  while y.len > 1 and y[0] == '0': y = y[1 .. ^1]
  if x.len != y.len: x.len > y.len else: x >= y

proc noteFor(s: LezPartSeam, amount: string): tuple[ok: bool, account: Account, detail: string] =
  ## The one shielded note of mine a payment of `amount` draws on — a transfer spends ONE
  ## note, never several. The account muster created when it covers it; otherwise the
  ## largest note the scan discovered (money received privately, a shield to my own key
  ## node included, lands at a discovered account). Raises LezScanBehind while the scan is
  ## catching up.
  let held = s.adapter.shieldedHoldings(s.ks)
  if held.len > 0 and decAtLeast(held[0].raw, amount): return (true, held[0].account, "")
  var pick = -1
  for i in 1 ..< held.len:
    if decAtLeast(held[i].raw, amount) and (pick < 0 or decAtLeast(held[i].raw, held[pick].raw)): pick = i
  if pick >= 0: return (true, held[pick].account, "")
  var largest = "0"
  for h in held:
    if decAtLeast(h.raw, largest): largest = h.raw
  (false, Account(), "no one shielded note of yours covers " & amount & " — a private transfer draws on one note, " &
                     "and your largest holds " & largest & " (across " & $held.len & " shielded accounts)")

proc refuse(s: LezPartSeam, t: PartTransfer): string =
  let served = s.adapter.describe()
  if t.chain != s.chain or served.chain != s.chain:
    return "this LEZ wallet pays on " & served.chain & ", the part settles on " & t.chain
  if t.asset != served.nativeAsset.symbol:
    return "only " & served.nativeAsset.symbol & " is paid privately so far (asked: " & t.asset & ")"
  if not t.to.startsWith("priv:"):
    return "a private split pays only a shielded key node, not " & t.to
  ""

method sendPart*(s: LezPartSeam, t: PartTransfer): tuple[ok: bool, tx, detail: string] =
  ## Shielded → shielded only: paying from a public account would take the shield rail and
  ## name the payer (and the amount) on the chain — refused, not quietly allowed.
  let why = s.refuse(t)
  if why.len > 0: return (false, "", why)
  try:
    var frm = s.payFrom
    if frm.id.len == 0:
      let (ok, account, detail) = s.noteFor(t.amount)
      if not ok: return (false, "", detail)
      frm = account
    if frm.form != afShielded:
      return (false, "", "a private split pays only from a shielded account — paying from " & frm.id &
                         " would name you, and the amount, on the chain")
    let native = s.adapter.describe().nativeAsset
    let prepared = s.adapter.prepareTransfer(frm, t.to, Amount(asset: native, raw: t.amount))
    let rail = parseEnum[TransferForm](parseJson(prepared.payload){"form"}.getStr())
    if rail != tfPrivate:
      return (false, "", "this payment would take the " & $rail & " rail; a private split takes only the private one")
    let r = s.adapter.submit(prepared, s.ks)
    s.lastRail = rail
    (true, r.id, "")
  except LezScanBehind as e:
    (false, "", e.msg & " — pay once it has; it cannot yet see the note it would spend")
  except CatchableError as e:
    (false, "", e.msg)

method partLanded*(s: LezPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  let f = s.adapter.finality(TxRef(chain: s.adapter.describe().chain, id: tx))
  case f.status
  of fsFinal: (true, "")
  of fsFailed: (false, tx & " failed on " & s.chain & ": " & f.detail)
  of fsPending: (false, "the private transfer is still proving / settling — " & f.detail)

method checkReceived*(s: LezPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  (false, "a private transfer cannot be looked up by its sender's reference; the creditor's scan matches it")

method matchReceived*(s: LezPartSeam, t: PartTransfer, reported: string,
                      claimed: HashSet[string]): tuple[ok: bool, reference, detail: string] =
  ## Scan MY wallet: a note that arrived at the split's payTo key node, of exactly this
  ## share, not already claimed. The reported reference is the payer's claim; it is not
  ## what proves receipt here — the note is.
  let why = s.refuse(t)
  if why.len > 0: return (false, "", why)
  try:
    for n in s.adapter.receivedNotes(s.ks):
      if n.keyNode != t.to or n.raw != t.amount: continue
      let r = noteRef(n.account.id)
      if r in claimed: continue
      return (true, r, "")
    (false, "", "no unclaimed private note of exactly " & t.amount & " has arrived at " & t.to[0 ..< min(t.to.len, 18)] &
                "… yet — a private payment names no payer; its distinct amount is how it is matched to its share")
  except LezScanBehind as e:
    (false, "", e.msg & " — a note may be waiting in a block it has not read yet")
  except CatchableError as e:
    (false, "", "the scan failed: " & e.msg)

method landedRef*(s: LezPartSeam, t: PartTransfer, tx: string): string =
  ## A private payment proves in the background: its send returns a marker, and the
  ## zone's own transaction hash is known once it lands. The report names that — the
  ## payer's own disclosure, inside the room (a private transaction's hash shows no
  ## payer, payee or amount on the chain).
  let h = s.adapter.resolvedTx(tx)
  if h.len > 0: h else: tx

method payDeadlineS*(s: LezPartSeam): float =
  ## The proving budget, then a block and a scan: a slow proof that still lands must
  ## not be abandoned.
  float(LezProveBudgetMs) / 1000.0 + 600.0
