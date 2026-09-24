## The Bitcoin multisig driver (exo-a50.2.3, Phase B): two families behind one Driver —
##   * btc.p2wsh-sortedmulti — OP_k <keys> OP_n OP_CHECKMULTISIG in a P2WSH output; each
##     owner signs every input's BIP-143 hash (DER, SIGHASH_ALL);
##   * btc.tapscript-multi-a — <K1> CHECKSIG <K2> CHECKSIGADD … <k> NUMEQUAL as the only
##     leaf of a P2TR output whose internal key is the NUMS point; each owner signs every
##     input's BIP-341/342 hash (Schnorr, SIGHASH_DEFAULT).
## An ACCOUNT is k of n compressed keys on a network; its address commits to exactly
## that policy, so a member's disclosure is checked by re-deriving the address — no
## chain read (btcDisclosureCheck). The EFFECT (btc-spend) names every input with its
## prevout (amount + scriptPubKey — the fee is implicit in BIP-143, so the proposal must
## carry them) and every output; the MATERIALIZATION is the list of per-input sighashes
## each owner signs. A CONTRIBUTION is one signer's signature for every input.
## Outside signers speak PSBT: exportPsbt / importPsbtContributions (seam S8).

import std/[json, strutils, sequtils, algorithm]
import ../dcbor/dcbor
import ../intents/materialization
import ./driver
import ./manifest
import ./profile
import ../bitcoin/[tx, script, sighash, taproot, keys, bech32, psbt, network]
import ../crypto/keystore
import ./inapp

type
  BtcAccount* = object
    family*: string          ## btc.p2wsh-sortedmulti | btc.tapscript-multi-a
    network*: BtcNetwork
    k*: int
    keys*: seq[seq[byte]]    ## 33-byte compressed, sorted
    witnessScript*: seq[byte] ## p2wsh
    leafScript*: seq[byte]    ## tapscript
    controlBlock*: seq[byte]  ## tapscript (NUMS internal key, single leaf)
    scriptPubKey*: seq[byte]
    address*: string
    chain*: string           ## CAIP-2
    accountId*: string       ## CAIP-10

  BtcMultisigDriver* = ref object of Driver
    account*: BtcAccount
    pending: seq[seq[byte]]  ## the sighashes contributions currently verify against

  ImportedContribution* = tuple[signer: string, contribution: Contribution]

const P2wshFamily* = "btc.p2wsh-sortedmulti"
const TapscriptFamily* = "btc.tapscript-multi-a"

proc btcAccount*(family, networkName: string, k: int, keys: seq[seq[byte]]): BtcAccount =
  let net = networkByName(networkName)
  result = BtcAccount(family: family, network: net, k: k, keys: sortedKeys(keys), chain: net.caip2)
  case family
  of P2wshFamily:
    result.witnessScript = sortedMultiScript(k, keys)
    result.scriptPubKey = p2wshScriptPubKey(result.witnessScript)
    result.address = encodeSegwitAddress(net.hrp, 0, result.scriptPubKey[2 .. ^1])
  of TapscriptFamily:
    result.leafScript = multiAScript(k, keys.mapIt(xonlyOfCompressed(it)))
    let m = merkle(tapLeaf(result.leafScript))
    let (q, parity) = outputKey(hexToBytes(NumsH), @(m.root))
    result.controlBlock = controlBlock(m.leaves[0], hexToBytes(NumsH), parity)
    result.scriptPubKey = p2trScriptPubKey(q)
    result.address = encodeSegwitAddress(net.hrp, 1, q)
  else: raise newException(BtcError, "not a Bitcoin multisig family: " & family)
  result.accountId = result.chain & ":" & result.address

proc newBtcMultisigDriver*(acct: BtcAccount): BtcMultisigDriver = BtcMultisigDriver(account: acct)

# ── the effect → a transaction ────────────────────────────────────────────────
proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

proc mapGet(m: CborValue, key: string): CborValue =
  if m.kind != ckMap: return cbNull()
  for (k, v) in m.pairs:
    if k.kind == ckText and k.t == key: return v
  cbNull()

proc spendOf*(e: Effect): tuple[tx: BtcTx, amounts: seq[uint64], spks: seq[seq[byte]]] =
  ## The transaction a btc-spend effect describes, with each input's prevout. Raises
  ## BtcError on anything malformed (an unparseable address, a missing prevout).
  if e.schemaId != "muster.effect.btc-spend.v1": raise newException(BtcError, "not a btc-spend effect")
  var t = BtcTx(version: 2)
  let loc = e.fieldOf("locktime")
  if loc.kind == ckUint: t.locktime = uint32(loc.u)
  let ins = e.fieldOf("inputs")
  let outs = e.fieldOf("outputs")
  if ins.kind != ckArray or outs.kind != ckArray or ins.arr.len == 0 or outs.arr.len == 0:
    raise newException(BtcError, "a spend needs inputs and outputs")
  for i in ins.arr:
    let txid = i.mapGet("txid"); let vout = i.mapGet("vout")
    let value = i.mapGet("value"); let spk = i.mapGet("scriptPubKey"); let sq = i.mapGet("sequence")
    if txid.kind != ckText or vout.kind != ckUint or value.kind != ckUint or spk.kind != ckBytes:
      raise newException(BtcError, "an input needs txid, vout, value and scriptPubKey")
    t.inputs.add TxIn(prevout: outpointFromHex(txid.t, uint32(vout.u)),
                      sequence: (if sq.kind == ckUint: uint32(sq.u) else: 0xfffffffd'u32))
    result.amounts.add value.u
    result.spks.add spk.b
  for o in outs.arr:
    let value = o.mapGet("value")
    if value.kind != ckUint: raise newException(BtcError, "an output needs a value")
    var spk: seq[byte]
    let a = o.mapGet("address")
    let s = o.mapGet("scriptPubKey")
    if a.kind == ckText: spk = scriptPubKeyOfAddress(hrpOfAddress(a.t), a.t)
    elif s.kind == ckBytes: spk = s.b
    else: raise newException(BtcError, "an output needs an address or a scriptPubKey")
    t.outputs.add TxOut(value: value.u, scriptPubKey: spk)
  result.tx = t

proc sighashesOf*(d: BtcMultisigDriver, e: Effect): seq[seq[byte]] =
  ## every input's signature hash, in the family's algorithm
  let (t, amounts, spks) = spendOf(e)
  for i in 0 ..< t.inputs.len:
    if d.account.family == P2wshFamily:
      result.add @(bip143Sighash(t, i, d.account.witnessScript, amounts[i], SighashAll.uint32))
    else:
      result.add @(bip341Sighash(t, i, amounts, spks, SighashDefault, @(tapLeafHash(d.account.leafScript))))

proc domainOf(d: BtcMultisigDriver): string =
  if d.account.family == P2wshFamily: "bip143.p2wsh.sortedmulti.v1" else: "bip341.tapscript.multi_a.v1"

method describe*(d: BtcMultisigDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: d.domainOf(), finality: finExternal,
                   threshold: d.account.k)

method environment*(d: BtcMultisigDriver): string = d.account.chain

method canonicalize*(d: BtcMultisigDriver, e: Effect): Materialization =
  ## The bytes the owners sign: every input's sighash, under the family domain + chain.
  ## A malformed spend canonicalizes to a sentinel no signature can match (signRefusal
  ## names what is wrong before anyone is asked to sign).
  var hs: seq[CborValue]
  try:
    for h in d.sighashesOf(e): hs.add cbBytes(h)
  except BtcError as err:
    return Materialization(bytes: encode(cbArray(@[cbText(d.domainOf()), cbText("invalid: " & err.msg)])))
  d.pending = hs.mapIt(it.b)
  Materialization(bytes: encode(cbArray(@[cbText(d.domainOf()), cbText(d.account.chain), cbArray(hs)])))

proc sighashesIn(m: Materialization): seq[seq[byte]] =
  try:
    let v = decode(m.bytes)
    if v.kind == ckArray and v.arr.len == 3 and v.arr[2].kind == ckArray:
      for h in v.arr[2].arr: result.add h.b
  except CatchableError: discard

method expectMaterialization*(d: BtcMultisigDriver, m: Materialization) = d.pending = sighashesIn(m)

proc contributionBytes(signer: seq[byte], sigs: seq[seq[byte]]): seq[byte] =
  encode(cbMap(@[(cbText("signer"), cbBytes(signer)), (cbText("sigs"), cbArray(sigs.mapIt(cbBytes(it))))]))

proc signContribution*(d: BtcMultisigDriver, e: Effect, pub33: seq[byte],
                       sign: proc(h: seq[byte]): seq[byte]): Contribution =
  ## One signer's contribution: a signature for every input (DER for P2WSH, BIP-340 for
  ## tapscript — `sign` makes it; the keystore does in-app, exo-a50.2.4).
  Contribution(bytes: contributionBytes(pub33, d.sighashesOf(e).mapIt(sign(it))))

proc verifyAgainst(d: BtcMultisigDriver, hashes: seq[seq[byte]], c: Contribution): string =
  ## the signer's key hex if every input's signature verifies for an account key, else ""
  var v: CborValue
  try: v = decode(c.bytes)
  except CatchableError: return ""
  let signer = v.mapGet("signer")
  let sigs = v.mapGet("sigs")
  if signer.kind != ckBytes or sigs.kind != ckArray: return ""
  if signer.b notin d.account.keys: return ""
  if hashes.len == 0 or sigs.arr.len != hashes.len: return ""
  for i, s in sigs.arr:
    if s.kind != ckBytes: return ""
    let ok = (if d.account.family == P2wshFamily: ecdsaVerifyDer(s.b, hashes[i], signer.b)
              else: s.b.len == 64 and schnorrVerify(s.b, hashes[i], xonlyOfCompressed(signer.b)))
    if not ok: return ""
  toHex(signer.b)

method verifyContribution*(d: BtcMultisigDriver, c: Contribution, round: int): bool =
  d.verifyAgainst(d.pending, c).len > 0

method identifyContributor*(d: BtcMultisigDriver, m: Materialization, c: Contribution): string =
  d.verifyAgainst(sighashesIn(m), c)

method signRefusal*(d: BtcMultisigDriver, e: Effect): string =
  ## Before anyone signs: every input must be THIS account's coins, the declared fee
  ## must be exactly inputs − outputs (BIP-143 signs only each input's own amount, so a
  ## wrong prevout would silently change the fee), and no output may be dust.
  var s: tuple[tx: BtcTx, amounts: seq[uint64], spks: seq[seq[byte]]]
  try: s = spendOf(e)
  except BtcError as err: return "not a valid Bitcoin spend: " & err.msg
  for i, spk in s.spks:
    if spk != d.account.scriptPubKey: return "input " & $i & " spends coins that are not this account's"
  var inSum, outSum: uint64
  for a in s.amounts: inSum += a
  for (i, o) in s.tx.outputs.pairs:
    if o.value < 546: return "output " & $i & " is dust (" & $o.value & " sat)"
    outSum += o.value
  if outSum > inSum: return "outputs exceed inputs"
  let fee = e.fieldOf("fee")
  if fee.kind != ckUint or fee.u != inSum - outSum:
    return "the declared fee is not inputs − outputs (" & $(inSum - outSum) & " sat)"
  ""

method profile*(d: BtcMultisigDriver): FamilyProfile =
  ## Both families: the protocol itself checks k of n (native); everyone signs the same
  ## per-input hashes; bound implicitly (a signature only spends these exact coins);
  ## UTXO ordering; signatures never expire; the address is derived; changing signers
  ## means a new address. At spend the chain learns the policy (the executed script) and
  ## who signed; there is no module or guard — nothing gets around the script.
  FamilyProfile(declared: true, family: d.account.family, settlement: "bitcoin",
    locus: loNative, scheme: scSharedBytes, commits: cmContent, binding: bdImplicit,
    ordering: orUtxo, expiry: exNone, setup: suDerive, signerChange: chNewAddress,
    revealsPolicy: rvAtSettle, revealsSigners: rvAtSettle, revealsEffect: evPublic,
    approverCost: acPerSignature, rounds: 1, secretState: false, maturity: maProduction,
    chain: d.account.chain, account: d.account.accountId, k: d.account.k,
    n: d.account.keys.len, bypassesKnown: true)

method manifest*(d: BtcMultisigDriver, effect: Effect): ActionManifest =
  ## Needs the chain reachable (a UTXO source to read prevouts and broadcast) and a key
  ## in the account; touches (spends) every input's coins; at spend the chain sees the
  ## whole transaction, the policy and who signed, and the node relaying it sees it first.
  var touches = @[touch(d.account.chain, tmWrite)]
  try:
    let (t, _, _) = spendOf(effect)
    for i in t.inputs:
      var r = i.prevout.txid
      for x in 0 ..< 16: swap(r[x], r[31 - x])
      touches.add touch("utxo:" & toHex(r) & ":" & $i.prevout.vout, tmWrite)
  except BtcError: discard
  ActionManifest(declared: true, agreement: d.describe(),
    requirements: @[req(rqEnvironment, d.account.chain), req(rqInfra, "bitcoind-rpc"),
                    req(rqAuthority, "btc-multisig-key", rpContributor)],
    discloses: @[row("outputs", obChainObserver), row("inputs", obChainObserver),
                 row("policy", obChainObserver), row("signers", obChainObserver),
                 row("signed-tx", obRpcProvider)],
    touches: touches)

# ── building a spend from the account's coins (exo-a50.2.5) ───────────────────
const DustLimit* = 546'u64   ## an output below this is non-standard: never made

proc inputWeight(acct: BtcAccount): int =
  ## An upper bound, in weight units, for one input of this account's spend: the
  ## non-witness part (outpoint, empty scriptSig, sequence) at 4 WU a byte, the witness
  ## at 1 — P2WSH: the dummy, k DER signatures at their 72-byte maximum + the hashtype,
  ## the witnessScript; tapscript: one slot per key (k Schnorr signatures, the rest
  ## empty), the leaf, the control block.
  let n = acct.keys.len
  let witness =
    if acct.family == P2wshFamily:
      compactSize(uint64(acct.k + 2)).len + 1 + acct.k * (1 + 73) + withSize(acct.witnessScript).len
    else:
      compactSize(uint64(n + 2)).len + acct.k * (1 + 64) + (n - acct.k) +
        withSize(acct.leafScript).len + withSize(acct.controlBlock).len
  4 * (32 + 4 + 1 + 4) + witness

proc vsizeEstimate(acct: BtcAccount, nIn: int, outSpks: seq[seq[byte]]): uint64 =
  var w = 4 * (4 + 4 + compactSize(uint64(nIn)).len + compactSize(uint64(outSpks.len)).len) + 2
  w += nIn * inputWeight(acct)
  for spk in outSpks: w += 4 * (8 + withSize(spk).len)
  uint64((w + 3) div 4)

proc buildBtcSpend*(acct: BtcAccount, utxos: seq[BtcUtxo], payTo: string, amount: uint64,
                    feeRate = 1, sequence = 0xfffffffd'u32, locktime = 0'u32): string =
  ## A btc-spend effect paying `amount` sat to `payTo` from this account's coins: the
  ## largest first until the payment and its fee are covered, the payee first, change
  ## back to the account unless it would be dust (then it goes to the fee). The fee is
  ## `feeRate` sat/vB over an UPPER bound of the signed size, declared as inputs −
  ## outputs, and the inputs are declared an external read (invariant 10): whoever
  ## proposes records where the coins were read from. Raises BtcError when the coins
  ## cannot pay — never a spend that could not be broadcast.
  if amount < DustLimit: raise newException(BtcError, "a payment below " & $DustLimit & " sat is dust")
  if feeRate < 1: raise newException(BtcError, "a fee rate is at least 1 sat/vB")
  let paySpk = scriptPubKeyOfAddress(hrpOfAddress(payTo), payTo)
  let mine = toHex(acct.scriptPubKey)
  var coins = utxos.filterIt(it.scriptPubKey.toLowerAscii() == mine)   # only coins this account can spend
  coins.sort(proc(a, b: BtcUtxo): int =
    if a.value != b.value: cmp(b.value, a.value)
    elif a.txid != b.txid: cmp(a.txid, b.txid)
    else: cmp(a.vout, b.vout))
  let rate = uint64(feeRate)
  var chosen: seq[BtcUtxo]
  var total: uint64
  for c in coins:
    if c.txid.len != 64 or hexToBytes(c.txid).len != 32:
      raise newException(BtcError, "a txid is 32 bytes: " & c.txid)
    chosen.add c
    total += c.value
    let bare = rate * vsizeEstimate(acct, chosen.len, @[paySpk])
    if total < amount + bare: continue
    let withChange = rate * vsizeEstimate(acct, chosen.len, @[paySpk, acct.scriptPubKey])
    var outs = %*[{"address": payTo, "value": amount}]
    var fee = total - amount
    if total >= amount + withChange and total - amount - withChange >= DustLimit:
      outs.add %*{"address": acct.address, "value": total - amount - withChange}
      fee = withChange
    var ins = newJArray()
    for u in chosen:
      ins.add %*{"txid": u.txid.toLowerAscii(), "vout": u.vout, "value": u.value,
                 "scriptPubKey": u.scriptPubKey.toLowerAscii(), "sequence": sequence}
    return $(%*{"effect": "btc-spend", "inputs": ins, "outputs": outs, "locktime": locktime,
                "fee": fee, "sources": {"inputs": "read"}})
  raise newException(BtcError, "not enough in the account: " & $total & " sat for " & $amount &
                               " sat and its fee at " & $feeRate & " sat/vB")

# ── finalizing: the signatures into the witnesses (exo-a50.2.5) ─────────────────
proc leafKeys(leaf: seq[byte]): seq[seq[byte]] =
  ## the x-only keys of a multi_a leaf, in script order (<32-byte push> CHECKSIG[ADD] …)
  var i = 0
  while i + 34 <= leaf.len and leaf[i] == 0x20'u8:
    result.add leaf[i + 1 .. i + 32]
    i += 34

proc finalizeSpend*(d: BtcMultisigDriver, e: Effect, accepted: seq[Contribution]): BtcTx =
  ## The spend with every input's witness filled from EXACTLY k of the accepted
  ## contributions — the first k signers in the script's key order, since CHECKMULTISIG
  ## consumes signatures in key order and multi_a sums to exactly k (NUMEQUAL). P2WSH:
  ## the dummy, the signatures + SIGHASH_ALL, the witnessScript. Tapscript: one slot per
  ## key, the last key's first (the first key checked pops the top), empty for a key
  ## that does not sign, then the leaf and the control block. The caller admits only
  ## contributions the driver accepts; raises BtcError below k.
  var (t, _, _) = spendOf(e)
  var bySigner: seq[(seq[byte], seq[seq[byte]])]
  for c in accepted:
    let v = decode(c.bytes)
    let signer = v.mapGet("signer")
    let sigs = v.mapGet("sigs")
    if signer.kind != ckBytes or sigs.kind != ckArray or sigs.arr.len != t.inputs.len: continue
    bySigner.add (signer.b, sigs.arr.mapIt(it.b))
  let order = (if d.account.family == P2wshFamily: d.account.keys else: leafKeys(d.account.leafScript))
  var slot = newSeq[seq[seq[byte]]](order.len)
  var used = 0
  for j, key in order:
    if used == d.account.k: break
    for (signer, sigs) in bySigner:
      let k2 = (if d.account.family == P2wshFamily: signer else: xonlyOfCompressed(signer))
      if k2 == key:
        slot[j] = sigs
        inc used
        break
  if used < d.account.k:
    raise newException(BtcError, $used & " of the " & $d.account.k & " signatures the account needs")
  for i in 0 ..< t.inputs.len:
    var w: seq[seq[byte]]
    if d.account.family == P2wshFamily:
      w.add newSeq[byte]()
      for j in 0 ..< order.len:
        if slot[j].len > 0: w.add slot[j][i] & @[SighashAll]
      w.add d.account.witnessScript
    else:
      for j in countdown(order.len - 1, 0):
        w.add (if slot[j].len > 0: slot[j][i] else: newSeq[byte]())
      w.add d.account.leafScript
      w.add d.account.controlBlock
    t.inputs[i].witness = w
  t

# ── PSBT, both ways (outside signers, seam S8) ─────────────────────────────────
proc exportPsbt*(d: BtcMultisigDriver, e: Effect): Psbt =
  ## The spend as a PSBT an outside signer (Keycard Shell, Sparrow, Bitcoin Core) signs:
  ## each input's prevout, and its witnessScript or tapleaf + control block.
  let (t, amounts, spks) = spendOf(e)
  result = newPsbt(t)
  for i in 0 ..< t.inputs.len:
    result.setWitnessUtxo(i, TxOut(value: amounts[i], scriptPubKey: spks[i]))
    if d.account.family == P2wshFamily:
      result.setWitnessScript(i, d.account.witnessScript)
    else:
      result.setTapInternalKey(i, hexToBytes(NumsH))
      result.setTapLeafScript(i, d.account.controlBlock, d.account.leafScript, TapscriptLeafVersion)

proc importPsbtContributions*(d: BtcMultisigDriver, e: Effect, p: Psbt): seq[ImportedContribution] =
  ## Every account key that signed EVERY input of this spend in `p` becomes a
  ## contribution — the same bytes a native approval makes, verified the same way. A PSBT
  ## of any other spend is refused (PsbtError), never partially imported.
  if canonicalBytes(p) != canonicalBytes(d.exportPsbt(e)):
    raise newException(PsbtError, "this PSBT is not the proposal's spend")
  let hashes = d.sighashesOf(e)
  let leafHash = (if d.account.family == TapscriptFamily: @(tapLeafHash(d.account.leafScript)) else: @[])
  for key in d.account.keys:
    var sigs: seq[seq[byte]]
    for i in 0 ..< p.inputs.len:
      var found: seq[byte]
      if d.account.family == P2wshFamily:
        for (pk, sig) in p.partialSigs(i):
          if pk == key and sig.len > 1 and sig[^1] == SighashAll: found = sig[0 ..< sig.len - 1]
      else:
        for (x, lh, sig) in p.tapScriptSigs(i):
          if x == xonlyOfCompressed(key) and lh == leafHash:
            if sig.len == 64: found = sig
            elif sig.len == 65 and sig[64] == SighashAll: found = sig[0 ..< 64]
      if found.len == 0: break
      sigs.add found
    if sigs.len == hashes.len:
      let c = Contribution(bytes: contributionBytes(key, sigs))
      if d.verifyAgainst(hashes, c).len > 0: result.add (signer: toHex(key), contribution: c)

proc btcAccountOfDisclosure*(family, chain, address: string, k: int,
                             signers: seq[string]): tuple[ok: bool, account: BtcAccount, detail: string] =
  ## Re-derive the account a member disclosed and check its address commits to exactly
  ## those keys and k — the verification a Bitcoin disclosure needs (no chain read).
  try:
    let net = networkByCaip2(chain)
    let acct = btcAccount(family, net.name, k, signers.mapIt(hexToBytes(it)))
    if acct.address != address.toLowerAscii():
      return (false, acct, "the address " & address & " does not commit to these " & $signers.len &
                           " keys and k=" & $k & " (they derive " & acct.address & ")")
    (true, acct, "the address commits to exactly these keys: " & $k & " of " & $signers.len)
  except CatchableError as e:
    (false, BtcAccount(), "not a valid Bitcoin account: " & e.msg)

method signInApp*(d: BtcMultisigDriver, e: Effect, ks: Keystore, attestDigest: array[32, byte]): InAppSig =
  ## The member's keystore signs every input — DER for P2WSH, BIP-340 for tapscript —
  ## with the SAME secp key it attests with (a recoverable signature over the attestation
  ## digest), so the approval is bound to the key that made it. A key that is not one of
  ## the account's makes a contribution the driver will reject, never a counted one.
  let pub = ks.btcPubKey()
  let signHash = proc(h: seq[byte]): seq[byte] =
    var a: array[32, byte]
    for i in 0 ..< 32: a[i] = h[i]
    if d.account.family == P2wshFamily: ks.signEcdsaDer(a) else: ks.signSchnorr(a)
  let c = d.signContribution(e, pub, signHash)
  InAppSig(handled: true, contribution: c.bytes, attestation: @(ks.sign(attestDigest)),
           keyRef: refOf(ks.address()))
