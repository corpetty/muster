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
  payFrom*: Account         ## the account this member pays from; empty = their shielded account
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
      for a in s.adapter.accounts(s.ks):
        if a.form == afShielded: frm = a
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
  except CatchableError as e:
    (false, "", "the scan failed: " & e.msg)
