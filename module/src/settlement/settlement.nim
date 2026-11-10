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

import std/[json, algorithm, strutils, sequtils, options, times, os]
import ../intents/materialization
import ../drivers/driver
import ../drivers/profile
import ../drivers/safe
import ../drivers/safe_rpc
import ../drivers/btc_multisig
import ../drivers/btc_frost        # the aggregate locus (Phase D)
import ../drivers/lez_frost        # a FROST group acting on LEZ (exo-55e)
import ../drivers/lez_msig         # lez-msig: approvals verified in-program (exo-0d3)
import ../lez/msig
import ../wallet/lez_msig_chain
import ../wallet/lez_msig_private  # its private posture, through the prover (exo-efa)
import stint
import ../drivers/lez_multisig
import ../lez/multisig
import ../lez/multisig_chain
import ../lez/tx as leztx       # the v0.3.0 line: settlement builds the transaction (exo-eb6.4 L3)
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

method watchDeadlineS*(s: Settlement): float {.base.} =
  ## How long a watch may legitimately stay pending; 0 = the host's default. A time-locked
  ## action waits out its lock before it can be final.
  0.0

proc watchWithin*(s: Settlement, txRef: TxRef, windowS: float, pollMs = 200): Finality =
  ## Finality, waited for within a wall-clock window: what a hosted call may spend on it
  ## on the module thread, never more (exo-14f). Pending past the window. A read that
  ## fails ends the wait at once, as pending: a node that did not answer will not answer
  ## in the next poll either, and the caller's pump keeps watching. Each read has its own
  ## budget (wallet/rpc_budget.nim), so the whole wait is at most the window plus one read.
  let until = epochTime() + windowS
  while true:
    try: result = s.watch(txRef)
    except CatchableError as e:
      return Finality(status: fsPending, detail: "could not read the chain: " & e.msg)
    if result.status != fsPending or epochTime() + float(pollMs) / 1000.0 >= until: return
    sleep(pollMs)

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
  if drv of BtcFrostDriver:
    # the aggregate locus (Phase D): t round-2 partials of one signer set aggregate into
    # one BIP-340 signature per input — the witness a single-sig key-path spend has
    let fd = BtcFrostDriver(drv)
    let refusal = fd.signRefusal(effect)
    if refusal.len > 0: return Assembled(ok: false, error: "not-settleable", detail: refusal)
    let cs = contributions.mapIt(Contribution(bytes: it.bytes))
    let need = fd.account.params.t
    let have = fd.completeSigners(effect, cs)
    if have < need:
      return Assembled(ok: false, error: "insufficient-signatures", have: have, need: need,
                       detail: $have & " of the " & $need & " partial signatures one signer set needs")
    var ft: BtcTx
    try: ft = fd.finalizeFrostSpend(effect, cs)
    except CatchableError as e:
      return Assembled(ok: false, error: "not-settleable", have: have, need: need, detail: e.msg)
    return Assembled(ok: true, have: have, need: need,
      tx: PreparedTx(chain: fd.account.chain, frm: s.relayer, to: fd.account.address,
                     payload: $(%*{"rawtx": toHex(ft.serialize(withWitness = true)), "txid": txidHex(ft)})))
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
  if effect.schemaId == ConfigSchema:
    # a config change (exo-267.6): re-read it (S5), count current members' approvals on
    # chain, and ExecuteConfig naming them and the change
    var ci: uint64
    var cc: ConfigAction
    try: (ci, cc) = lezConfigOf(effect)
    except ValueError as e: return Assembled(ok: false, error: "not-settleable", detail: e.msg)
    let cp = chain.readAccount(proposalPda(a.scheme, a.program, a.createKey, ci))
    if not cp.found: return Assembled(ok: false, error: "not-settleable", detail: "no proposal #" & $ci & " on " & a.chain)
    let cwhy = d.checkRead(effect, "proposal", cp.data)
    if cwhy.len > 0: return Assembled(ok: false, error: "not-settleable", detail: cwhy)
    try:
      let st = chain.readAccount(a.statePda)
      if not st.found: return Assembled(ok: false, error: "not-settleable", detail: "no multisig state on " & a.chain)
      let state = decodeState(st.data)
      let approvers = decodeProposal(cp.data, a.layout).approved.filterIt(it in state.members)
      if approvers.len < state.threshold:
        return Assembled(ok: false, error: "insufficient-approvals", have: approvers.len, need: state.threshold,
                         detail: $approvers.len & " of the " & $state.threshold & " approvals are on chain")
      var change = %*{"change": (case cc.kind
                                 of caAddMember: "add"
                                 of caRemoveMember: "remove"
                                 of caChangeThreshold: "threshold")}
      case cc.kind
      of caAddMember, caRemoveMember: change["member"] = %lhx(cc.member)
      of caChangeThreshold: change["threshold"] = %cc.threshold
      return Assembled(ok: true, have: approvers.len, need: state.threshold,
        tx: PreparedTx(chain: a.chain, frm: s.relayer, to: lhx(a.statePda),
                       payload: $(%*{"op": "execute-config", "lez": "v0.3", "createKey": lhx(a.createKey), "index": ci,
                                     "approvers": approvers.mapIt(lhx(it)), "config": change,
                                     "proposal": lhx(proposalPda(a.scheme, a.program, a.createKey, ci))})))
    except LezDecodeError as e:
      return Assembled(ok: false, error: "not-settleable", detail: "the chain's accounts do not decode: " & e.msg)
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
    have = decodeProposal(prop.data, a.layout).approved.countIt(it in state.members)
  except LezDecodeError as e:
    return Assembled(ok: false, error: "not-settleable", detail: "the chain's accounts do not decode: " & e.msg)
  if have < need:
    return Assembled(ok: false, error: "insufficient-approvals", have: have, need: need,
                     detail: $have & " of the " & $need & " approvals are on chain (height " & $prop.height & ")")
  if a.layout == plV03:
    # the v0.3 port: Execute names the approvals it counts — those the chain holds from
    # current members — and carries the call the proposal commits to, which S5 just
    # matched to what the room reviewed (exo-eb6.4.4)
    let state = decodeState(chain.readAccount(a.statePda).data)
    let approvers = decodeProposal(prop.data, a.layout).approved.filterIt(it in state.members)
    return Assembled(ok: true, have: have, need: need,
      tx: PreparedTx(chain: a.chain, frm: s.relayer, to: lhx(a.statePda),
                     payload: $(%*{"op": "execute", "lez": "v0.3", "createKey": lhx(a.createKey), "index": idx,
                                   "approvers": approvers.mapIt(lhx(it)),
                                   "call": {"target": lhx(action.target),
                                            "shards": action.shards.mapIt(%*{"account": lhx(it.account),
                                                                              "program": lhx(it.program)}),
                                            "data": lhx(action.data), "pdaSeeds": action.pdaSeeds.mapIt(lhx(it))},
                                   "proposal": lhx(proposalPda(a.scheme, a.program, a.createKey, idx))})))
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
  ## Landed and not Executed is a refusal: on LEZ v0.3 a refused transaction is included
  ## (and pays); on v0.2.4 one that landed always took (exo-eb6.4.4).
  let f = s.adapter.finality(txRef)
  if f.status != fsFinal or s.watching.len == 0 or not (s.adapter of LezMultisigChain): return f
  try:
    let r = LezMultisigChain(s.adapter).readAccount(s.watching)
    if r.found and decodeProposal(r.data, LezMultisigChain(s.adapter).layout).status == psExecuted:
      Finality(status: fsFinal, detail: "Executed on chain (height " & $r.height & ")")
    else: Finality(status: fsFailed, detail: "the Execute was included and the chain refused it: the proposal " &
                                             "is not Executed (on LEZ v0.3 a refused transaction is included, and pays)")
  except CatchableError as e: Finality(status: fsPending, detail: "could not read the proposal: " & e.msg)

# ── a FROST group acting on LEZ (exo-55e) ──────────────────────────────────────
type LezFrostSettlement* = ref object of Settlement

proc zx(b: seq[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

method assemble*(s: LezFrostSettlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled =
  ## Re-read the account's nonce (S5): a signature for a nonce the chain moved past can
  ## never land, so it is refused and the room proposes again. On v0.3, a transfer the
  ## account cannot cover with its fee cap at that nonce is refused too: the chain would
  ## include it, charge its gas and move nothing, and report no outcome (exo-eb6.4.6). One
  ## it covers can only take effect once included: the chain authenticates the nonce
  ## before it runs anything, so no other transaction of the group's lands in between,
  ## nothing but the group's own signature debits its account, and the fee it reserves is
  ## at most the declared cap. Then one aggregate BIP-340 signature from a complete signer
  ## set, verified under x(Q) before anything is sent.
  if not (drv of LezFrostDriver):
    return Assembled(ok: false, error: "not-settleable", detail: "a LEZ FROST settlement needs a LEZ FROST driver")
  if not (s.adapter of LezMultisigChain):
    return Assembled(ok: false, error: "not-settleable", detail: "no LEZ chain to send through")
  let d = LezFrostDriver(drv)
  let refusal = d.signRefusal(effect)
  if refusal.len > 0: return Assembled(ok: false, error: "not-settleable", detail: refusal)
  let call = callOf(effect)
  try:
    let now = LezMultisigChain(s.adapter).readAccount(d.account.accountId)
    if now.nonce != call.nonces[0]:
      return Assembled(ok: false, error: "not-settleable",
        detail: "the account's nonce moved (" & $call.nonces[0] & " signed, " & $now.nonce &
                " on chain): this signature can never land — propose again")
    if call.v3:
      let amount = nativeTransferOut(call, d.account.accountId)
      if amount.isNone:
        return Assembled(ok: false, error: "not-settleable", detail: d.signRefusal(effect))
      let need = amount.get + call.fee.get.maxFee
      if now.balance < need:
        return Assembled(ok: false, error: "not-settleable",
          detail: "the account holds " & $now.balance & ", which does not cover the transfer (" & $amount.get &
                  ") and its fee cap (" & $call.fee.get.maxFee & "): sent, it would be included, pay its " &
                  "gas and move nothing")
  except CatchableError as e:
    return Assembled(ok: false, error: "not-settleable", detail: "could not read the account's nonce: " & e.msg)
  let cs = contributions.mapIt(Contribution(bytes: it.bytes))
  let msgs = d.frostMessages(effect)
  let need = d.account.group.params.t
  let have = completeSignersFrost(d.account.group, msgs, cs)
  if have < need:
    return Assembled(ok: false, error: "insufficient-signatures", have: have, need: need,
                     detail: $have & " of the " & $need & " partial signatures one signer set needs")
  var sig: seq[byte]
  try: sig = aggregateFrost(d.account.group, msgs, cs)[0]
  except CatchableError as e:
    return Assembled(ok: false, error: "not-settleable", have: have, need: need, detail: e.msg)
  if call.v3:
    # the v0.3.0 line (exo-eb6.4 L3): the transaction is built here, whole, from the
    # agreed call and the one aggregate witness; the chain only carries it
    let ws = @[LezWitness(signature: sig, xonly: d.account.group.xonly)]
    let m = message3Of(call)
    return Assembled(ok: true, have: have, need: need,
      tx: PreparedTx(chain: d.account.chain, frm: s.relayer, to: d.account.address,
                     payload: $(%*{"lez": "v0.3", "leeTx": zx(leeTxPublic(m, ws)), "hash": publicTxHash(m, ws)})))
  Assembled(ok: true, have: have, need: need,
    tx: PreparedTx(chain: d.account.chain, frm: s.relayer, to: d.account.address,
                   payload: $(%*{"program": zx(call.program), "accounts": call.accounts.mapIt(zx(it)),
                                 "signers": call.signers.mapIt(zx(it)), "words": call.words.mapIt(int64(it)),
                                 "sig": zx(sig), "xonly": zx(d.account.group.xonly)})))

method submit*(s: LezFrostSettlement, tx: PreparedTx, ks: Keystore): TxRef =
  ## Send the call with the aggregate as its one witness; a refusal raises.
  proc unz(h: string): seq[byte] =
    for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
  let p = parseJson(tx.payload)
  if p{"lez"}.getStr() == "v0.3":
    let r3 = LezMultisigChain(s.adapter).sendBuilt(unz(p["leeTx"].getStr()), p["hash"].getStr())
    if not r3.ok: raise newException(WalletError, "the chain refused it: " & r3.error)
    return TxRef(chain: tx.chain, id: r3.hash)
  let r = LezMultisigChain(s.adapter).sendWitnessed(unz(p["program"].getStr()),
    p["accounts"].getElems().mapIt(unz(it.getStr())), p["signers"].getElems().mapIt(unz(it.getStr())),
    p["words"].getElems().mapIt(uint32(it.getBiggestInt())), @[(unz(p["sig"].getStr()), unz(p["xonly"].getStr()))])
  if not r.ok: raise newException(WalletError, "the chain refused it: " & r.error)
  TxRef(chain: tx.chain, id: r.hash)

method watch*(s: LezFrostSettlement, txRef: TxRef): Finality =
  ## Final once included. On v0.2.4 a refused call was dropped; on v0.3 one is included
  ## too, so assemble sends only a native transfer the account covers at its signed nonce,
  ## which can only take effect (exo-eb6.4.6).
  s.adapter.finality(txRef)

# ── lez-msig (exo-0d3): one transaction carries the proposal and its approvals ──
type LezMsigSettlement* = ref object of Settlement
  ## What the last submit sent, so watch can judge it by the state it changed and, for a
  ## time-locked action, send ExecuteQueued itself once the lock ends.
  sentKind: InstrKind
  proposal: MsigProposal
  driver: LezMsigDriver
  etaMs, expiresMs: uint64
  queueSlackMs*: uint64     ## how late a Queue may land; 0 = QueueSlackMs
  queuedRef: string         ## the ExecuteQueued this settlement sent itself, once the lock ended

const QueueSlackMs = 120_000'u64   ## a Queue claims to land within two minutes

proc msigChainOf(s: LezMsigSettlement): MsigChain =
  if s.adapter of MsigChain: MsigChain(s.adapter) else: nil

proc myExecutor(c: MsigChain, d: LezMsigDriver, p: MsigProposal): tuple[ok: bool, signed: Option[MsigSigned], why: string] =
  ## An execution signature, when the multisig asks for one: THIS member's approval key,
  ## which must hold EXECUTE.
  if d.account.config.openExecution: return (true, none(MsigSigned), "")
  if not (c of MsigLive): return (false, none(MsigSigned), "no keystore to sign the execution with")
  let ks = MsigLive(c).ks
  let label = myMsigLabel(ks, d.account)
  let key = ks.lezMemberKey(label)
  let m = d.account.config.memberOf(key)
  if m.isNone or (m.get.roles and RoleExecute) == 0:
    return (false, none(MsigSigned), "this multisig asks an EXECUTE member to sign the execution, and you are not one")
  var h: array[32, byte]
  let em = executeMsg(proposalId(p))
  for i in 0 ..< 32: h[i] = em[i]
  (true, some(MsigSigned(key: key, sig: ks.lezMemberSign(label, h))), "")

proc isoMs(ms: uint64): string = $fromUnix(int64(ms div 1000)).utc

method assemble*(s: LezMsigSettlement, drv: Driver, effect: Effect,
                 contributions: seq[SettleContribution]): Assembled =
  ## Read the multisig's state (the program's own copy is the one that counts), then build
  ## the one instruction this proposal needs now: ExecuteQueued if it is queued and its lock
  ## has ended; Queue if the multisig has a time lock; else Execute. Approvals are the
  ## driver-verified ones, one per member, the proposer's included.
  if not (drv of LezMsigDriver):
    return Assembled(ok: false, error: "not-settleable", detail: "a lez-msig settlement needs a lez-msig driver")
  let c = s.msigChainOf()
  if c == nil: return Assembled(ok: false, error: "not-settleable", detail: "no LEZ chain to send through")
  let d = LezMsigDriver(drv)
  let refusal = d.signRefusal(effect)
  if refusal.len > 0: return Assembled(ok: false, error: "not-settleable", detail: refusal)
  let p = proposalOf(effect)
  let id = proposalId(p)
  var r: MsigRead
  try: r = c.readMsig(d.account.address)
  except CatchableError as e:
    return Assembled(ok: false, error: "not-settleable", detail: "could not read the multisig: " & e.msg)
  if not r.found: return Assembled(ok: false, error: "not-settleable", detail: "the multisig is not on chain")
  let st = r.state
  let now = c.nowMs()
  var ins: MsigInstruction
  var have, need = 0
  var queued = -1
  for i, q in st.queue:
    if q.nonce == p.nonce and q.proposalId == id: queued = i
  if queued >= 0:
    let q = st.queue[queued]
    if now < q.etaMs:
      return Assembled(ok: false, error: "not-settleable",
                       detail: "queued: its time lock ends at " & isoMs(q.etaMs))
    if now >= q.expiresMs:
      return Assembled(ok: false, error: "not-settleable", detail: "expired: the proposal expired at " & isoMs(q.expiresMs))
    ins = MsigInstruction(kind: ikExecuteQueued, proposal: p, atMs: q.etaMs)
  else:
    if p.epoch != st.epoch:
      return Assembled(ok: false, error: "not-settleable",
        detail: "stale-epoch: approvals were gathered under epoch " & $p.epoch & "; the configuration changed since (epoch " &
                $st.epoch & "): propose again")
    if not st.nonceFree(p.nonce):
      return Assembled(ok: false, error: "not-settleable", detail: "nonce-spent: nonce " & $p.nonce & " was already executed, queued or cancelled")
    if now >= p.expiresMs:
      return Assembled(ok: false, error: "not-settleable", detail: "expired: the proposal expired at " & isoMs(p.expiresMs))
    let msg = approveMsg(id)
    var approvals: seq[MsigSigned]
    var proposerSigned = false
    for ct in contributions:
      let sg = signedOf(Contribution(bytes: ct.bytes))
      if sg.isNone or approvals.anyIt(it.key == sg.get.key): continue
      let m = st.config.memberOf(sg.get.key)
      if m.isNone or not verifySig(sg.get.key, msg, sg.get.sig): continue
      if (m.get.roles and RoleApprove) == 0 and sg.get.key != p.proposer: continue
      if sg.get.key == p.proposer: proposerSigned = true
      approvals.add sg.get
    let weight = approvalWeight(st.config, approvals.mapIt(it.key))
    have = int(weight)
    need = int(st.config.threshold)
    if not proposerSigned:
      return Assembled(ok: false, error: "insufficient-signatures", have: have, need: need,
                       detail: "the proposer's own approval is missing")
    if weight < st.config.threshold:
      return Assembled(ok: false, error: "insufficient-signatures", have: have, need: need,
                       detail: "approvals weigh " & $weight & "; the threshold is " & $st.config.threshold)
    if st.config.timelockMs > 0 and p.action.kind != akCancel:
      let at = now + (if s.queueSlackMs > 0: s.queueSlackMs else: QueueSlackMs)
      if at + st.config.timelockMs >= p.expiresMs:
        return Assembled(ok: false, error: "not-settleable",
          detail: "the time lock (" & $(st.config.timelockMs div 1000) & " s) would end after the proposal expires")
      ins = MsigInstruction(kind: ikQueue, proposal: p, approvals: approvals, atMs: at)
    else:
      ins = MsigInstruction(kind: ikExecute, proposal: p, approvals: approvals)
  let ex = c.myExecutor(d, p)
  if not ex.ok: return Assembled(ok: false, error: "not-settleable", have: have, need: need, detail: ex.why)
  ins.executor = ex.signed
  let env = envelopePublic(d.account.createKey, ins)
  let rows = msigShards(c.program, d.account.address, ins)
  s.sentKind = ins.kind
  s.proposal = p
  s.driver = d
  s.expiresMs = p.expiresMs
  s.etaMs = (if ins.kind == ikQueue: ins.atMs + st.config.timelockMs else: 0)
  Assembled(ok: true, have: have, need: need,
    tx: PreparedTx(chain: d.account.chain, frm: s.relayer, to: hexOf(d.account.address),
                   payload: $(%*{"lez": "v0.3", "msig": $ins.kind, "envelope": hexOf(env), "op": hexOf(borsh(ins)),
                                 "rows": rows.mapIt(%*{"account": hexOf(it.account), "program": hexOf(it.program)}),
                                 "proposal": proposalJson(p)})))

proc rowsOf(p: JsonNode): seq[LezShard] =
  proc unz(h: string): seq[byte] =
    for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
  for r in p["rows"]: result.add LezShard(account: unz(r["account"].getStr()), program: unz(r["program"].getStr()))

method submit*(s: LezMsigSettlement, tx: PreparedTx, ks: Keystore): TxRef =
  ## From this member's own funded LEZ account; a refusal to send raises.
  proc unz(h: string): seq[byte] =
    for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
  let p = parseJson(tx.payload)
  let c = s.msigChainOf()
  # a private multisig's instruction goes to its prover, which builds the envelope with the
  # group's keys and proves it over the latest note (exo-efa)
  let r = (if c of MsigPrivate: MsigPrivate(c).sendOp(unz(p["op"].getStr()))
           else: c.sendMsig(rowsOf(p), unz(p["envelope"].getStr())))
  if not r.ok: raise newException(WalletError, "the sequencer refused it: " & r.error)
  TxRef(chain: tx.chain, id: r.hash)

method watch*(s: LezMsigSettlement, txRef: TxRef): Finality =
  ## Judged by the state, never by inclusion: a refused instruction is included too. An
  ## executed proposal has its nonce spent and nothing queued under it. A queued one waits
  ## out its lock; then this member sends ExecuteQueued and watches that.
  let c = s.msigChainOf()
  if c == nil or s.driver == nil: return s.adapter.finality(txRef)
  if not c.included(txRef.id):
    if txRef.id.startsWith("job:"): return Finality(status: fsPending, detail: "proving, then sending")
    return Finality(status: fsPending, detail: "sent; waiting for the chain to include it")
  if c of MsigPrivate and MsigPrivate(c).failure(txRef.id).len > 0:
    # a private execution the program refuses fails while proving: nothing was sent
    return Finality(status: fsFailed, detail: "the program refused it while proving; nothing was sent: " &
                                              MsigPrivate(c).failure(txRef.id))
  if s.queuedRef.len > 0 and c of MsigPrivate:
    # a private multisig's note moves only once the ExecuteQueued it proved lands
    let pc = MsigPrivate(c)
    if not pc.included(s.queuedRef): return Finality(status: fsPending, detail: "the lock ended; proving the execution")
    if pc.failure(s.queuedRef).len > 0:
      return Finality(status: fsFailed, detail: "the program refused the execution while proving: " & pc.failure(s.queuedRef))
  let r = c.readMsig(s.driver.account.address)
  if not r.found: return Finality(status: fsFailed, detail: "the multisig is no longer on chain")
  let id = proposalId(s.proposal)
  let isQueued = r.state.queue.anyIt(it.nonce == s.proposal.nonce and it.proposalId == id)
  case s.sentKind
  of ikQueue:
    if not isQueued:
      if r.state.nonceFree(s.proposal.nonce):
        return Finality(status: fsFailed, detail: "the program refused the queue (included; nothing changed)")
      return Finality(status: fsFailed, detail: "no longer queued: cancelled")
    if c.nowMs() < s.etaMs:
      return Finality(status: fsPending, detail: "queued: its time lock ends at " & isoMs(s.etaMs))
    # the lock has ended: execute it, and watch that
    var ins = MsigInstruction(kind: ikExecuteQueued, proposal: s.proposal, atMs: s.etaMs)
    let ex = c.myExecutor(s.driver, s.proposal)
    if not ex.ok: return Finality(status: fsPending, detail: "queued and ready, waiting on an EXECUTE member: " & ex.why)
    ins.executor = ex.signed
    let sent = (if c of MsigPrivate: MsigPrivate(c).sendOp(borsh(ins))
                else: c.sendMsig(msigShards(c.program, s.driver.account.address, ins),
                                 envelopePublic(s.driver.account.createKey, ins)))
    if not sent.ok: return Finality(status: fsPending, detail: "the lock ended; sending failed, retrying: " & sent.error)
    s.sentKind = ikExecuteQueued
    s.queuedRef = sent.hash
    return Finality(status: fsPending, detail: "the lock ended; executing (" & sent.hash & ")")
  else:
    if not r.state.nonceFree(s.proposal.nonce) and not isQueued:
      return Finality(status: fsFinal, detail: "executed at height " & $r.height)
    if s.sentKind == ikExecuteQueued and isQueued:
      return Finality(status: fsPending, detail: "executing the queued action")
    Finality(status: fsFailed, detail: "the program refused it (included; nothing changed)")

proc msigAccountOf*(s: LezMsigSettlement): Option[LezMsigAccount] =
  ## The multisig this settlement acted for, once it assembled.
  if s.driver != nil: some(s.driver.account) else: none(LezMsigAccount)

proc chainRefOf*(s: LezMsigSettlement, r: TxRef): string =
  ## What the settlement is looked up by outside the room: the transaction's hash. A private
  ## multisig's submit answers with the prover's job ("job:<id>"); its hash is known only once
  ## the prover sent it, and "" until then (exo-efa).
  let c = s.msigChainOf()
  if c != nil and c of MsigPrivate and r.id.startsWith("job:"): MsigPrivate(c).txHashOf(r.id)
  else: r.id

method watchDeadlineS*(s: LezMsigSettlement): float =
  ## Until the proposal expires: a queued action may wait out its whole lock.
  if s.expiresMs == 0 or s.msigChainOf() == nil: return 0.0
  let now = s.msigChainOf().nowMs()
  if s.expiresMs <= now: 60.0 else: float(s.expiresMs - now) / 1000.0 + 60.0

proc settlementFor*(drv: Driver, adapter: ChainAdapter, relayer: Account): Settlement =
  ## The settlement a driver's family needs — read from its PROFILE. nil when the
  ## family settles nowhere (a room family) or the driver declares nothing (unsupported).
  let p = drv.profile()
  if not p.declared or p.settlement == "none": return nil
  case p.family
  of "evm.safe": SafeSettlement(family: p.family, adapter: adapter, relayer: relayer)
  of P2wshFamily, TapscriptFamily, FrostFamily: BitcoinSettlement(family: p.family, adapter: adapter, relayer: relayer)
  of LezMultisigFamily: LezMultisigSettlement(family: p.family, adapter: adapter, relayer: relayer)
  of LezFrostFamily: LezFrostSettlement(family: p.family, adapter: adapter, relayer: relayer)
  of LezMsigFamily, LezMsigPrivateFamily: LezMsigSettlement(family: p.family, adapter: adapter, relayer: relayer)
  else: nil
