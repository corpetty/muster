## The settlement seam (exo-a50.1.5; seam S6 of docs/design/multisig-landscape.md).
##
## A family is scheme × settlement. The DRIVER says what a contribution is and whether
## it counts; the SETTLEMENT turns an executable intent's contributions into a chain
## transaction and carries it through the ChainAdapter seam (wallet/adapter.nim):
##
##   assemble(driver, effect, contributions) → a PreparedTx, or a refusal naming why
##   submit(tx, keystore)                    → a TxRef, through the adapter
##   watch(txRef)                            → finality, through the adapter
##
## settlementFor picks one from the driver's family PROFILE — never from a policy
## string, never by branching on a concrete driver type in the core. A room family
## (settlement "none") or an undeclared / unsupported driver has NO settlement: nil,
## never a guess. The Safe settlement is the first tenant; Phase B's Bitcoin settlement
## (exo-a50.2.5) and Phase C's LEZ multisig settlement (exo-0c9, the vote locus: count the
## votes on chain, then Execute) sit beside it.

import std/[json, algorithm, strutils, sequtils]
import ../intents/materialization
import ../drivers/driver
import ../drivers/profile
import ../drivers/safe
import ../drivers/safe_rpc
import ../drivers/btc_multisig
import ../drivers/lez_multisig
import ../lez/multisig
import ../lez/multisig_chain
import ../bitcoin/tx
import ../crypto/secp256k1
import ../crypto/keystore
import ../wallet/types
import ../wallet/adapter

type
  SettleContribution* = tuple[contributor: string, bytes: seq[byte]]
    ## a contribution from the log: who (as recorded) and the opaque bytes

  Assembled* = object
    ok*: bool
    error*: string        ## "insufficient-signatures" | "not-settleable" | …
    detail*: string
    have*, need*: int     ## contributions the driver accepted / the threshold
    tx*: PreparedTx

  Settlement* = ref object of RootObj
    family*: string       ## the registry family this settles
    adapter*: ChainAdapter
    relayer*: Account     ## who sends the settling transaction (pays its fee)

method assemble*(s: Settlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled {.base.} =
  Assembled(ok: false, error: "not-settleable", detail: "no settlement for " & s.family)

method submit*(s: Settlement, tx: PreparedTx, ks: Keystore): TxRef {.base.} =
  ## Through the adapter seam, from the relayer the settlement was configured with.
  s.adapter.submit(tx, ks)

method watch*(s: Settlement, txRef: TxRef): Finality {.base.} =
  s.adapter.finality(txRef)

# ── the Safe ─────────────────────────────────────────────────────────────────
type SafeSettlement* = ref object of Settlement

proc cmpAddress*(a, b: Address): int =
  ## ascending byte order — the order Safe.checkSignatures requires of its signers
  for i in 0 ..< 20:
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  0

proc hex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

method assemble*(s: SafeSettlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled =
  ## Re-derive the safeTxHash from the effect (never trusted from the log, invariant 1),
  ## keep each contribution only if it recovers to one of the Safe's owners (the
  ## driver's own rule), one per owner, ascending by owner (Safe.checkSignatures), and
  ## refuse below the threshold. The calldata is the real ten-argument execTransaction.
  if not (drv of SafeDriver):
    return Assembled(ok: false, error: "not-settleable", detail: "a Safe settlement needs a Safe driver")
  let sd = SafeDriver(drv)
  let mat = canonicalize(sd, effect)
  var hash: array[32, byte]
  for i in 0 ..< min(32, mat.bytes.len): hash[i] = mat.bytes[i]
  var signed: seq[(Address, Signature65)]
  var seen: seq[Address]
  for c in contributions:
    if c.bytes.len != 65: continue
    var sig: Signature65
    for i in 0 ..< 65: sig[i] = c.bytes[i]
    if not recoversToOwner(hash, sig, sd.owners): continue
    let who = ecrecover(hash, sig)
    if who in seen: continue
    seen.add who
    signed.add (who, sig)
  if signed.len < sd.threshold:
    return Assembled(ok: false, error: "insufficient-signatures", have: signed.len, need: sd.threshold,
                     detail: $signed.len & " of the " & $sd.threshold & " owner signatures the Safe needs")
  signed.sort(proc(a, b: (Address, Signature65)): int = cmpAddress(a[0], b[0]))
  var sigbytes: seq[byte]
  for (_, sig) in signed: sigbytes.add @sig
  let calldata = assembleExecTransaction(toSafeTx(effect), sigbytes)
  let safeHex = hex0x(sd.safe)
  Assembled(ok: true, have: signed.len, need: sd.threshold,
    tx: PreparedTx(chain: s.relayer.chain, frm: s.relayer, to: safeHex,
                   payload: $(%*{"to": safeHex, "data": hex0x(calldata), "gas": 400_000})))

# ── Bitcoin (exo-a50.2.5) ─────────────────────────────────────────────────────
type BitcoinSettlement* = ref object of Settlement

method assemble*(s: BitcoinSettlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled =
  ## Re-derive every input's sighash from the effect (invariant 1) and admit a
  ## contribution only if the driver names a key of the account for it, one per key;
  ## refuse below k and refuse a spend the driver itself would refuse to sign. The
  ## witnesses are the driver's to finalize (its script, its key order); the payload is
  ## the raw transaction — self-contained, since its fee comes out of its own inputs —
  ## and its txid. Nothing but the witnesses differs from the reviewed spend.
  if not (drv of BtcMultisigDriver):
    return Assembled(ok: false, error: "not-settleable", detail: "a Bitcoin settlement needs a Bitcoin multisig driver")
  let bd = BtcMultisigDriver(drv)
  let refusal = bd.signRefusal(effect)
  if refusal.len > 0: return Assembled(ok: false, error: "not-settleable", detail: refusal)
  let m = canonicalize(bd, effect)
  var accepted: seq[Contribution]
  var seen: seq[string]
  for c in contributions:
    let who = identifyContributor(bd, m, Contribution(bytes: c.bytes))
    if who.len == 0 or who in seen: continue
    seen.add who
    accepted.add Contribution(bytes: c.bytes)
  let need = bd.account.k
  if accepted.len < need:
    return Assembled(ok: false, error: "insufficient-signatures", have: accepted.len, need: need,
                     detail: $accepted.len & " of the " & $need & " signatures the account needs")
  var t: BtcTx
  try: t = bd.finalizeSpend(effect, accepted)
  except BtcError as e:
    return Assembled(ok: false, error: "not-settleable", have: accepted.len, need: need, detail: e.msg)
  Assembled(ok: true, have: accepted.len, need: need,
    tx: PreparedTx(chain: bd.account.chain, frm: s.relayer, to: bd.account.address,
                   payload: $(%*{"rawtx": toHex(t.serialize(withWitness = true)), "txid": txidHex(t)})))

# ── the LEZ multisig program (exo-0c9) ─────────────────────────────────────────
type LezMultisigSettlement* = ref object of Settlement
  watching: seq[byte]      ## the proposal PDA the last submit asked to Execute

proc lhx(b: seq[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

method assemble*(s: LezMultisigSettlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled =
  ## The vote locus: the program already holds the votes, so nothing is assembled from
  ## signatures. Re-read the pointer (S5 again — never settle content the room did not
  ## review), count the approvals the CHAIN holds against the threshold the chain holds
  ## (the room's receipts are not the tally), and at k prepare an Execute with the
  ## effect's target accounts, from the relayer member.
  if not (drv of LezMultisigDriver):
    return Assembled(ok: false, error: "not-settleable", detail: "a LEZ multisig settlement needs a LEZ multisig driver")
  if not (s.adapter of LezMultisigChain):
    return Assembled(ok: false, error: "not-settleable", detail: "no LEZ multisig chain to read the votes from")
  let d = LezMultisigDriver(drv)
  let chain = LezMultisigChain(s.adapter)
  let a = d.account
  var idx: uint64
  var action: LezAction
  try: (idx, action) = lezActionOf(effect)
  except ValueError as e: return Assembled(ok: false, error: "not-settleable", detail: e.msg)
  let prop = chain.readAccount(proposalPda(a.scheme, a.program, a.createKey, idx))
  if not prop.found:
    return Assembled(ok: false, error: "not-settleable", detail: "no proposal #" & $idx & " on " & a.chain)
  let why = d.checkRead(effect, "proposal", prop.data)
  if why.len > 0: return Assembled(ok: false, error: "not-settleable", detail: why)
  var need: int
  var have: int
  try:
    let st = chain.readAccount(a.statePda)
    if not st.found: return Assembled(ok: false, error: "not-settleable", detail: "no multisig state on " & a.chain)
    let state = decodeState(st.data)
    need = state.threshold
    have = decodeProposal(prop.data).approved.countIt(it in state.members)
  except LezDecodeError as e:
    return Assembled(ok: false, error: "not-settleable", detail: "the chain's accounts do not decode: " & e.msg)
  if have < need:
    return Assembled(ok: false, error: "insufficient-approvals", have: have, need: need,
                     detail: $have & " of the " & $need & " approvals are on chain (height " & $prop.height & ")")
  Assembled(ok: true, have: have, need: need,
    tx: PreparedTx(chain: a.chain, frm: s.relayer, to: lhx(a.statePda),
                   payload: $(%*{"op": "execute", "createKey": lhx(a.createKey), "index": idx,
                                 "accounts": action.accounts.mapIt(lhx(it)),
                                 "proposal": lhx(proposalPda(a.scheme, a.program, a.createKey, idx))})))

method submit*(s: LezMultisigSettlement, tx: PreparedTx, ks: Keystore): TxRef =
  ## Through the chain seam, from the relayer member; remembers which proposal it asked
  ## to Execute, so watch can wait for the chain to say so.
  s.watching = @[]
  try:
    let h = parseJson(tx.payload){"proposal"}.getStr()
    for i in 0 ..< h.len div 2: s.watching.add byte(parseHexInt(h[2*i .. 2*i+1]))
  except CatchableError: discard
  s.adapter.submit(tx, ks)

method watch*(s: LezMultisigSettlement, txRef: TxRef): Finality =
  ## Final only when the transaction landed AND the chain says the proposal is Executed.
  let f = s.adapter.finality(txRef)
  if f.status != fsFinal or s.watching.len == 0 or not (s.adapter of LezMultisigChain): return f
  try:
    let r = LezMultisigChain(s.adapter).readAccount(s.watching)
    if r.found and decodeProposal(r.data).status == psExecuted:
      Finality(status: fsFinal, detail: "Executed on chain (height " & $r.height & ")")
    else: Finality(status: fsPending, detail: "included, but the chain does not show the proposal Executed")
  except CatchableError as e: Finality(status: fsPending, detail: "could not read the proposal: " & e.msg)

proc settlementFor*(drv: Driver, adapter: ChainAdapter, relayer: Account): Settlement =
  ## The settlement a driver's family needs — read from its PROFILE. nil when the
  ## family settles nowhere (a room family) or the driver declares nothing (unsupported).
  let p = drv.profile()
  if not p.declared or p.settlement == "none": return nil
  case p.family
  of "evm.safe": SafeSettlement(family: p.family, adapter: adapter, relayer: relayer)
  of P2wshFamily, TapscriptFamily: BitcoinSettlement(family: p.family, adapter: adapter, relayer: relayer)
  of LezMultisigFamily: LezMultisigSettlement(family: p.family, adapter: adapter, relayer: relayer)
  else: nil
