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

import std/[json, tables, strutils, times]
import ./types
import ./adapter
import ./lez_core
import ./lez_readiness
import ../crypto/keystore

const ChainId* = "lez:testnet"
const
  PublicLabel* = "muster-public"       ## the wallet's name for the public account muster made
  ShieldedLabel* = "muster-shielded"   ## …and for its shielded account (the key node it shares)

type
  LezAdapter* = ref object of ChainAdapter
    core: LezCore
    native: AssetId
    cached: seq[Account]                 ## our public + private accounts (created once)
    keyNode: Table[string, LezAccount]   ## our private account id -> its npk/vpk
    submitted: Table[string, tuple[priv: bool, polls: int, async: bool]]  ## txId -> finality state
    resolved: Table[string, string]      ## an async send's marker -> the zone's transaction hash
    lastScanAt: float                    ## when this wallet's scan last stepped (epoch seconds)

  LezScanBehind* = object of WalletError
    ## The wallet's scan has not reached the chain tip yet — not a failure, and never
    ## "nothing arrived": a note may be waiting in a block it has not read.

proc newLezAdapter*(core: LezCore): LezAdapter =
  LezAdapter(
    core: core,
    native: AssetId(chain: ChainId, symbol: "LEZ", kind: akNative, decimals: 9),
    keyNode: initTable[string, LezAccount](),
    submitted: initTable[string, tuple[priv: bool, polls: int, async: bool]](),
    resolved: initTable[string, string]())

proc scanToTip(a: LezAdapter) =
  ## One step of the scan (LezCore.sync): returns once it is at the tip; raises
  ## LezScanBehind while it is still catching up, WalletError on a failed scan.
  a.lastScanAt = epochTime()
  case a.core.sync()
  of LezSyncOk: discard
  of LezSyncBehind:
    raise newException(LezScanBehind, "your LEZ wallet is still scanning the chain (block " &
                       $a.core.synced & " of " & $a.core.tip & ") — it will catch up on its own")
  else: raise newException(WalletError, "LEZ sync failed")

method describe*(a: LezAdapter): ChainDescriptor =
  ChainDescriptor(chain: ChainId, displayName: "Logos Execution Zone",
                  nativeAsset: a.native, accountForms: @[afPublic, afShielded],
                  finality: finDelayed)

method securityLevel*(a: LezAdapter): SecurityLevel =
  ## The real LEZ offers the real confidentiality level (exo-1ec.5): a shielded rail where
  ## the amount is public only if a party is public (the education square, docs/design/
  ## lez-adapter.md). The adapter declares `real` here; WHICH rail a given transfer takes,
  ## and its per-rail disclosure, is the manifest's job — this is the seam's capability.
  securityLevel(
    axisLevel(rungNull, "chain does not authenticate the room member"),
    axisLevel(rungNull, "reads from untrusted RPC (invariant 8)"),
    axisLevel(rungReal, "shielded rail — private/shield/deshield hide amount and parties"))

method accounts*(a: LezAdapter, ks: Keystore): seq[Account] =
  ## One public + one private account from this identity. The LEZ wallet persists, and
  ## names them itself (PublicLabel / ShieldedLabel), so a relaunch finds the same two —
  ## a creditor's payTo does not move, and no account is minted (or, public, registered
  ## on chain) per start (exo-884). Only a missing one is created, then labelled.
  if a.cached.len == 0:
    let held = a.core.listAccounts()
    proc own(label: string, kind: LezAccountKind): LezAccount =
      let id = a.core.labelled(label)
      if id.len > 0:
        for la in held:
          if la.id == id and la.kind == kind: return la
    var pub = own(PublicLabel, lakPublic)
    if pub.id.len == 0:
      pub = a.core.createAccount(lakPublic)
      discard a.core.labelAccount(PublicLabel, pub)
    var prv = own(ShieldedLabel, lakPrivate)
    if prv.id.len == 0:
      prv = a.core.createAccount(lakPrivate)
      discard a.core.labelAccount(ShieldedLabel, prv)
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
  let raw = a.core.getBalanceRaw(account.id, account.form == afPublic)
  if raw.len == 0:
    raise newException(WalletError, "LEZ balance unavailable for " & account.id)
  amount(asset, raw)

const LezPublicFeeCap = "134400000"
  ## What lez_core declares as a public transaction's max_fee on LEZ v0.3: the LEZ wallet's
  ## max_fee_for(DEFAULT_GAS_LIMIT) = (2_000_000 + 100_000) × 64 (lez/wallet/src/lib.rs @
  ## v0.3.0; the same value lez/tx.nim's defaultFee declares, held to LEZ's own vectors)

method estimateFee*(a: LezAdapter, frm: Account, to: string, amt: Amount): FeeEstimate =
  ## LEZ v0.3 (exo-eb6.4): a privacy-preserving transaction — a shield, a deshield, a
  ## private transfer — carries no fee field and pays none ("fee-exempt under the interim
  ## policy", the sequencer's fees.rs). Its cost is the proof, minutes of the sender's own
  ## machine, so the note says so (a job, not an interaction; see the labbook). A public
  ## transfer pays a fee, declared up to the cap and the rest refunded: a plain transfer
  ## paid 2_968 base units on a local v0.3 zone.
  let shielded = frm.form == afShielded or to.startsWith("priv:")
  if shielded:
    FeeEstimate(fee: amount(a.native, "0"),
                note: "fee-exempt on LEZ v0.3; the cost is the proof — proving takes minutes")
  else:
    FeeEstimate(fee: amount(a.native, LezPublicFeeCap),
                note: "public transfer fee: at most " & LezPublicFeeCap &
                      " base units, the unused part refunded (a plain transfer pays a few thousand)")

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
  # "pending" == an ASYNC core fired the proof in the background (never blocked the
  # module); finality() polls it. A real txHash == a sync core (the fake), which uses
  # the modelled delay (shielded pending→final; public immediate).
  a.submitted[res.txHash] = (priv: form in {tfShield, tfPrivate}, polls: 0,
                             async: res.txHash == "pending")
  a.resolved.del(res.txHash)
  TxRef(chain: ChainId, id: res.txHash)

method finality*(a: LezAdapter, txRef: TxRef): Finality =
  ## Poll, never assert. A public transfer settles at once. A shielded one is DELAYED:
  ## it proves and settles, so it reports `pending` until a scan confirms — the "read
  ## right after a transfer is stale" reality, made honest instead of an optimistic
  ## `final`. `sync` (called during the poll) is what makes a received note discoverable.
  if txRef.id notin a.submitted:
    return Finality(status: fsFinal, detail: "no pending record")
  var s = a.submitted[txRef.id]
  # Async (real core): the proof ran in the background — poll its actual completion,
  # never an optimistic final. Until the ~7-minute proof lands it stays pending.
  if s.async:
    let r = a.core.pollTransfer()
    if not r.done:
      return Finality(status: fsPending, detail: "proving in the background…")
    if r.result.success:
      if r.result.txHash.len > 0: a.resolved[txRef.id] = r.result.txHash
      return Finality(status: fsFinal,
                      detail: "settled" & (if r.result.txHash.len > 0: " · " & r.result.txHash else: ""))
    return Finality(status: fsFailed,
                    detail: (if r.result.error.len > 0: r.result.error else: "transfer failed"))
  if not s.priv:
    return Finality(status: fsFinal, detail: "public transfer settled")
  inc s.polls
  a.submitted[txRef.id] = s
  if s.polls == 1:
    let code = a.core.sync()
    if code == LezSyncBehind:
      s.polls = 0
      a.submitted[txRef.id] = s
      return Finality(status: fsPending, detail: "the wallet's scan is still catching up to the chain tip")
    if code != LezSyncOk:
      return Finality(status: fsFailed, detail: "sync failed")
    return Finality(status: fsPending, detail: "proving/settling — the note is being scanned in")
  Finality(status: fsFinal, detail: "shielded transfer settled")

proc scanStep*(a: LezAdapter, minGapS = 0.0): tuple[ran: bool, code: int] =
  ## One bounded step of this wallet's scan toward the tip (LezCore.sync): what a pump
  ## runs while a private split waits on this member, so the scan is at the tip before a
  ## payment has to be sent or found (exo-270a). Never while this wallet is proving —
  ## lez_core serializes the wallet, and a scan queued behind a proof times out — then
  ## (ran: false, LezSyncBehind). With `minGapS`, a step is skipped when a scan already
  ## stepped that recently (a creditor's confirmation scans too) — so a pump's tick never
  ## holds the module thread for two steps.
  if a.core.proving(): return (false, LezSyncBehind)
  if minGapS > 0 and epochTime() - a.lastScanAt < minGapS: return (false, LezSyncBehind)
  a.lastScanAt = epochTime()
  (true, a.core.sync())

proc scanProgress*(a: LezAdapter): tuple[synced, tip: int] =
  ## Where this wallet's scan last got to, and the chain's tip then (0, 0 before any scan).
  (a.core.synced, a.core.tip)

proc resolvedTx*(a: LezAdapter, txId: string): string =
  ## The zone's transaction hash for a send that proved in the background (its TxRef is
  ## the "pending" marker), once finality has seen it land; "" until then.
  a.resolved.getOrDefault(txId, "")

# ── funding + discovery, beyond the ChainAdapter seam ──────────────────────────

proc receiveAddresses*(a: LezAdapter, ks: Keystore): seq[tuple[form, address: string]] =
  ## The addresses this instance can SHARE to be paid (the recipient half of Mode A's
  ## request→share→send). A public account shares its id; a shielded account shares its
  ## KEY NODE ("priv:<npk>:<vpk>") — because a shielded payment addresses a key node,
  ## not an id, and publishing it is both how you receive privately AND your consent to
  ## be paid. WHICH one you share is your own disclosure choice: a public id names you
  ## as payee, a key node does not.
  for acc in a.accounts(ks):
    if acc.form == afPublic:
      result.add (form: "public", address: acc.id)
    elif acc.id in a.keyNode:
      let kn = a.keyNode[acc.id]
      result.add (form: "shielded", address: "priv:" & kn.npk & ":" & kn.vpk)

proc syncPrivate*(a: LezAdapter): seq[Account] =
  ## Scan for received private notes and return every private account now discoverable
  ## (the receive-by-scan step: a payment you didn't name lands here). Raises on a
  ## failed scan. This is how a recipient finds an incoming shielded transfer.
  a.scanToTip()
  for la in a.core.listAccounts():
    if la.kind == lakPrivate:
      result.add Account(chain: ChainId, form: afShielded, id: la.id)

proc receivedNotes*(a: LezAdapter, ks: Keystore): seq[tuple[account: Account, keyNode, raw: string]] =
  ## Scan, then every private note this wallet has RECEIVED — not the accounts it created —
  ## with the key node it arrived at ("priv:<npk>:<vpk>") and its balance. What a creditor
  ## matches a private payment against (exo-a90.9): the note names no payer, so the key
  ## node says which request it answers and the amount says whose share it is. Raises on
  ## a failed scan or an unanswerable balance — never a false "nothing arrived" — and
  ## raises LezScanBehind while the scan has not reached the tip.
  a.scanToTip()
  var created: seq[string]
  for acc in a.accounts(ks): created.add acc.id
  for la in a.core.listAccounts():
    if la.kind != lakPrivate or la.id in created: continue
    let raw = a.core.getBalanceRaw(la.id, false)
    if raw.len == 0: raise newException(WalletError, "LEZ balance unavailable for " & la.id)
    result.add (account: Account(chain: ChainId, form: afShielded, id: la.id),
                keyNode: "priv:" & la.npk & ":" & la.vpk, raw: raw)

proc shieldedHoldings*(a: LezAdapter, ks: Keystore): seq[tuple[account: Account, raw: string]] =
  ## After a scan to the tip, every private account this wallet holds with its balance:
  ## the one muster created first, then every note it discovered. On the zone, money
  ## received privately — a shield to your own key node included — lands at a DISCOVERED
  ## account (the sender picks the identifier), so the created one is often empty; and a
  ## transfer draws on ONE of these, never their sum. Raises LezScanBehind while the scan
  ## is catching up, WalletError on a failed scan or an unanswerable balance.
  a.scanToTip()
  var created: seq[string]
  for acc in a.accounts(ks):
    if acc.form == afShielded: created.add acc.id
  var found: seq[tuple[account: Account, raw: string]]
  for la in a.core.listAccounts():
    if la.kind != lakPrivate: continue
    let raw = a.core.getBalanceRaw(la.id, false)
    if raw.len == 0: raise newException(WalletError, "LEZ balance unavailable for " & la.id)
    let entry = (account: Account(chain: ChainId, form: afShielded, id: la.id), raw: raw)
    if la.id in created: result.add entry else: found.add entry
  result.add found

proc lezStatusOf*(a: LezAdapter, minRaw = "0"): tuple[state, detail: string] {.gcsafe.} =
  ## LEZ account readiness for THIS adapter's zone (exo-44b L2): met/missing/unknown,
  ## for the readiness `lez-account` requirement. Keeps `core` private; the host wraps
  ## this into a Grade closure. Detects only — provisioning is the LEZ Wallet App.
  lezAccountStatus(a.core, minRaw)

proc provision*(a: LezAdapter, ks: Keystore): tuple[account, state, detail: string] =
  ## Headless LEZ provisioning FALLBACK (exo-44b, the no-broker path). Ensure this
  ## instance has a public LEZ account, and say whether it holds native LEZ yet. The
  ## account keys stay in lez_core; muster drives lez_core directly (the sanctioned
  ## core-to-core pattern), so this needs neither the app-to-app broker nor the LEZ Wallet
  ## App. It is the FALLBACK, not the default: delegating to the LEZ Wallet App stays
  ## preferred for UX and for keeping keys in one home.
  ##
  ## It funds nothing. LEZ v0.3 has no faucet (exo-eb6.4), and a fresh public account is
  ## claimed on chain only by its first funded transfer, so "met" means it holds native
  ## LEZ, and "missing" names the account someone who holds some must send to.
  let accs = a.accounts(ks)                 # creates public + shielded on first call
  var pub: Account
  for acc in accs:
    if acc.form == afPublic: pub = acc
  let (s, d) = a.lezStatusOf("1")
  if s == "missing":
    return (pub.id, s, "no native LEZ yet: send some to " & pub.id &
            " from an account that holds it (LEZ v0.3 has no faucet)")
  (pub.id, s, d)
