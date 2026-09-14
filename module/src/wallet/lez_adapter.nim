## The LEZ ChainAdapter — a real Logos Execution Zone chain behind the wallet seam,
## driving the LEZ wallet through the `LezCore` interface (a fake in tests, the `lp_*`
## `lez_core` client in production, P-L3). Design: docs/design/lez-adapter.md.
##
## The LEZ is NOT EVM. Its divergences the adapter has to honour:
##   • two account forms from one identity — a public id and a private key node that
##     RECEIVES BY SCAN (a payment lands at an account the recipient didn't create;
##     `sync` discovers it), so a private send takes the recipient's npk/vpk, not an id;
##   • delayed settlement — a shielded transfer proves (minutes) and finality is a poll
##     that stays `pending` until the note settles, never an assertion;
##   • three failure conventions (empty string / non-zero int / `success:false`
##     envelope) — each translated here into a `WalletError` raise, so a failed read is
##     never a false zero and a rejected transfer is never a false receipt.
##
## Signing is internal to the LEZ wallet (`lez_core` holds it), so unlike the EVM
## adapter this one does not use muster's Keystore to sign — the seam still hands it in.

import std/[json, tables, strutils]
import ./types
import ./adapter
import ./lez_core
import ../crypto/keystore

const ChainId* = "lez:testnet"

type
  LezAdapter* = ref object of ChainAdapter
    core: LezCore
    native: AssetId
    cached: seq[Account]                 ## our public + private accounts (created once)
    keyNode: Table[string, LezAccount]   ## our private account id -> its npk/vpk
    submitted: Table[string, tuple[priv: bool, polls: int]]  ## txId -> finality state

proc newLezAdapter*(core: LezCore): LezAdapter =
  LezAdapter(
    core: core,
    native: AssetId(chain: ChainId, symbol: "LEZ", kind: akNative, decimals: 9),
    keyNode: initTable[string, LezAccount](),
    submitted: initTable[string, tuple[priv: bool, polls: int]]())

method describe*(a: LezAdapter): ChainDescriptor =
  ChainDescriptor(chain: ChainId, displayName: "Logos Execution Zone",
                  nativeAsset: a.native, accountForms: @[afPublic, afShielded],
                  finality: finDelayed)

method accounts*(a: LezAdapter, ks: Keystore): seq[Account] =
  ## One public + one private account from this identity. Created once and cached —
  ## the LEZ wallet persists them; re-creating per call would mint new ids each time.
  if a.cached.len == 0:
    let pub = a.core.createAccount(lakPublic)
    let prv = a.core.createAccount(lakPrivate)
    a.keyNode[prv.id] = prv
    a.cached = @[
      Account(chain: ChainId, form: afPublic, id: pub.id),
      Account(chain: ChainId, form: afShielded, id: prv.id)]
  a.cached

method assets*(a: LezAdapter): seq[AssetId] = @[a.native]

method balance*(a: LezAdapter, account: Account, asset: AssetId): Amount =
  ## Raise on an unanswerable read (the LEZ returns "" — never a false zero). A
  ## received private note's balance shows against the DISCOVERED account after sync,
  ## not against a published id (receive-by-scan).
  let raw = a.core.getBalanceRaw(account.id)
  if raw.len == 0:
    raise newException(WalletError, "LEZ balance unavailable for " & account.id)
  amount(asset, raw)

method estimateFee*(a: LezAdapter, frm: Account, to: string, amt: Amount): FeeEstimate =
  ## A shielded transfer pays a PROOF cost, not gas — and the proof takes minutes, so
  ## the note says so honestly (this is a job, not an interaction; see the labbook).
  let shielded = frm.form == afShielded or to.startsWith("priv:")
  FeeEstimate(fee: amount(a.native, "1000000"),
              note: (if shielded: "shielded proof cost — proving takes minutes"
                     else: "public transfer fee"))

# The `to` convention: a public destination is a plain account id; a SHIELDED
# destination is "priv:<npk>:<vpk>" — the recipient's key node, since a shielded send
# addresses a key node, not an id (the module invents the identifier). The RAIL is the
# (source form, destination kind) square: public/public, public/private (shield),
# private/public (deshield), private/private.
proc railFor(frm: Account, to: string): tuple[form: TransferForm, seamTo: string] =
  let destShielded = to.startsWith("priv:")
  var seamTo = to
  if destShielded:
    let parts = to["priv:".len .. ^1].split(':')
    if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0:
      raise newException(WalletError, "shielded destination must be priv:<npk>:<vpk>")
    seamTo = parts[0] & ":" & parts[1]     # the seam takes the bare key node "npk:vpk"
  elif to.len == 0:
    raise newException(WalletError, "empty destination")
  let srcShielded = frm.form == afShielded
  let form =
    if not srcShielded and not destShielded: tfPublic
    elif not srcShielded and destShielded:   tfShield
    elif srcShielded and not destShielded:   tfDeshield
    else:                                    tfPrivate
  (form, seamTo)

method prepareTransfer*(a: LezAdapter, frm: Account, to: string, amt: Amount): PreparedTx =
  ## Build (not submit) — so the transfer is reviewable before it's signed/proved. The
  ## payload carries the rail + the seam destination + the DISCLOSURE (what this rail
  ## puts on the public record) so the review can show the honesty before committing.
  let r = railFor(frm, to)
  let disc = disclosureOf(r.form)
  let payload = $(%*{"form": $r.form, "to": r.seamTo,
                     "discloses": {"amount": disc.amount, "payer": disc.payer, "payee": disc.payee}})
  PreparedTx(chain: ChainId, frm: frm, to: to, amount: amt,
             fee: a.estimateFee(frm, to, amt), payload: payload)

method submit*(a: LezAdapter, tx: PreparedTx, ks: Keystore): TxRef =
  ## Execute the transfer through lez_core on its rail. A `success:false` envelope (or
  ## an empty / unparseable one) is a raise — never a false receipt. The LEZ wallet
  ## signs internally, so the keystore is unused here.
  let d = parseJson(tx.payload)
  let form = parseEnum[TransferForm](d{"form"}.getStr())
  let res = a.core.transfer(form, tx.frm.id, d{"to"}.getStr(), tx.amount.raw)
  if not res.success:
    raise newException(WalletError, "LEZ transfer failed: " &
                       (if res.error.len > 0: res.error else: "success=false"))
  # A shielded landing (shield/private) settles by scan → delayed finality; a public
  # landing (public/deshield) is immediate.
  a.submitted[res.txHash] = (priv: form in {tfShield, tfPrivate}, polls: 0)
  TxRef(chain: ChainId, id: res.txHash)

method finality*(a: LezAdapter, txRef: TxRef): Finality =
  ## Poll, never assert. A public transfer settles at once. A shielded one is DELAYED:
  ## it proves and settles, so it reports `pending` until a scan confirms — the "read
  ## right after a transfer is stale" reality, made honest instead of an optimistic
  ## `final`. `sync` (called during the poll) is what makes a received note discoverable.
  if txRef.id notin a.submitted:
    return Finality(status: fsFinal, detail: "no pending record")
  var s = a.submitted[txRef.id]
  if not s.priv:
    return Finality(status: fsFinal, detail: "public transfer settled")
  inc s.polls
  a.submitted[txRef.id] = s
  if s.polls == 1:
    if a.core.sync() != 0:
      return Finality(status: fsFailed, detail: "sync failed")
    return Finality(status: fsPending, detail: "proving/settling — the note is being scanned in")
  Finality(status: fsFinal, detail: "shielded transfer settled")

# ── funding + discovery, beyond the ChainAdapter seam ──────────────────────────

proc claimFaucet*(a: LezAdapter, pinataId: string, account: Account, nonce = 0) =
  ## Fund an account from the pinata faucet. Raises on a `success:false` envelope.
  let res = a.core.claimPinata(pinataId, account.id, nonce)
  if not res.success:
    raise newException(WalletError, "pinata claim failed: " & res.error)

proc syncPrivate*(a: LezAdapter): seq[Account] =
  ## Scan for received private notes and return every private account now discoverable
  ## (the receive-by-scan step: a payment you didn't name lands here). Raises on a
  ## failed scan. This is how a recipient finds an incoming shielded transfer.
  if a.core.sync() != 0:
    raise newException(WalletError, "LEZ sync failed")
  for la in a.core.listAccounts():
    if la.kind == lakPrivate:
      result.add Account(chain: ChainId, form: afShielded, id: la.id)
