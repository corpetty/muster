## PSBT — BIP-174 version 0 with the BIP-371 taproot fields (exo-a50.2.2).
##
## The format signers OUTSIDE muster speak (Keycard Shell, Sparrow, Coldcard, Bitcoin
## Core): muster exports a PSBT for them and imports the signatures they add. Parsing is
## strict on everything the BIPs make invalid (magic, missing/duplicated/typed-key
## errors, a signed or witness-serialized global tx, wrong map counts, wrong field
## lengths) and lossless on everything else: fields are kept in order, unknown and
## proprietary ones included, so a valid PSBT re-serializes byte-for-byte.
##
## Muster never hashes PSBT bytes (invariant 5 — the encoding is not canonical: field
## order, xpubs, derivation paths and proprietary data all vary). `canonicalBytes` is
## the dCBOR of the SPEND itself: the unsigned tx, each input's prevout (amount +
## scriptPubKey) and the script it spends through.

import std/[base64, strutils]
import ../dcbor/dcbor
import ./tx

type
  PsbtError* = object of CatchableError

  PsbtKV* = object
    key*: seq[byte]      ## the whole key: type byte + key data
    value*: seq[byte]

  Psbt* = object
    tx*: BtcTx                   ## the unsigned transaction (PSBT_GLOBAL_UNSIGNED_TX)
    globals*: seq[PsbtKV]        ## every other global field, in order
    inputs*: seq[seq[PsbtKV]]
    outputs*: seq[seq[PsbtKV]]

const Magic = [0x70'u8, 0x73, 0x62, 0x74, 0xff]   # "psbt" 0xff

# key types
const
  GUnsignedTx = 0x00'u8
  InNonWitnessUtxo = 0x00'u8
  InWitnessUtxo = 0x01'u8
  InPartialSig = 0x02'u8
  InSighashType = 0x03'u8
  InRedeemScript = 0x04'u8
  InWitnessScript = 0x05'u8
  InBip32 = 0x06'u8
  InFinalScriptSig = 0x07'u8
  InFinalScriptWitness = 0x08'u8
  InTapKeySig = 0x13'u8
  InTapScriptSig = 0x14'u8
  InTapLeafScript = 0x15'u8
  InTapBip32 = 0x16'u8
  InTapInternalKey = 0x17'u8
  InTapMerkleRoot = 0x18'u8
  OutRedeemScript = 0x00'u8
  OutWitnessScript = 0x01'u8
  OutBip32 = 0x02'u8
  OutTapInternalKey = 0x05'u8
  OutTapTree = 0x06'u8
  OutTapBip32 = 0x07'u8

proc bad(msg: string) {.noreturn.} = raise newException(PsbtError, msg)

# ── reading ──────────────────────────────────────────────────────────────────
type R = object
  b: seq[byte]
  p: int

proc take(r: var R, n: int): seq[byte] =
  if n < 0 or r.p + n > r.b.len: bad("truncated PSBT")
  result = r.b[r.p ..< r.p + n]
  r.p += n

proc cs(r: var R): int =
  let f = r.take(1)[0]
  case f
  of 0xfd: (let x = r.take(2); int(x[0]) or (int(x[1]) shl 8))
  of 0xfe: (let x = r.take(4); int(x[0]) or (int(x[1]) shl 8) or (int(x[2]) shl 16) or (int(x[3]) shl 24))
  of 0xff: bad("absurd PSBT length")
  else: int(f)

proc readMap(r: var R): seq[PsbtKV] =
  while true:
    let kl = r.cs()
    if kl == 0: return
    let k = r.take(kl)
    let v = r.take(r.cs())
    for e in result:
      if e.key == k: bad("duplicate key in a PSBT map")
    result.add PsbtKV(key: k, value: v)

# ── field rules (BIP-174 + BIP-371) ─────────────────────────────────────────────
proc keyData(kv: PsbtKV): seq[byte] = kv.key[1 .. ^1]

proc checkInput(m: seq[PsbtKV]) =
  for kv in m:
    let t = kv.key[0]
    let kd = kv.keyData()
    case t
    of InNonWitnessUtxo, InWitnessUtxo, InSighashType, InRedeemScript, InWitnessScript,
       InFinalScriptSig, InFinalScriptWitness, InTapKeySig, InTapInternalKey, InTapMerkleRoot:
      if kd.len != 0: bad("input field 0x" & toHex([t]) & " takes no key data")
    of InPartialSig, InBip32:
      if kd.len != 33 and kd.len != 65: bad("input field 0x" & toHex([t]) & " key must be a public key")
    of InTapScriptSig:
      if kd.len != 64: bad("PSBT_IN_TAP_SCRIPT_SIG key must be x-only key + leaf hash (64 bytes)")
    of InTapLeafScript:
      if kd.len < 33 or (kd.len - 33) mod 32 != 0 or (kd.len - 33) div 32 > 128:
        bad("PSBT_IN_TAP_LEAF_SCRIPT control block has the wrong length")
    of InTapBip32:
      if kd.len != 32: bad("PSBT_IN_TAP_BIP32_DERIVATION key must be an x-only key")
    else: discard
    case t
    of InSighashType: (if kv.value.len != 4: bad("sighash type is 4 bytes"))
    of InTapKeySig, InTapScriptSig: (if kv.value.len != 64 and kv.value.len != 65: bad("a taproot signature is 64 or 65 bytes"))
    of InTapInternalKey, InTapMerkleRoot: (if kv.value.len != 32: bad("a taproot key / root is 32 bytes"))
    of InWitnessUtxo:
      var rr = R(b: kv.value)
      discard rr.take(8)
      discard rr.take(rr.cs())
      if rr.p != rr.b.len: bad("witness UTXO has trailing bytes")
    of InNonWitnessUtxo: discard parseTx(kv.value)
    else: discard

proc checkOutput(m: seq[PsbtKV]) =
  for kv in m:
    let t = kv.key[0]
    let kd = kv.keyData()
    case t
    of OutRedeemScript, OutWitnessScript, OutTapInternalKey, OutTapTree:
      if kd.len != 0: bad("output field 0x" & toHex([t]) & " takes no key data")
    of OutBip32:
      if kd.len != 33 and kd.len != 65: bad("PSBT_OUT_BIP32_DERIVATION key must be a public key")
    of OutTapBip32:
      if kd.len != 32: bad("PSBT_OUT_TAP_BIP32_DERIVATION key must be an x-only key")
    else: discard
    if t == OutTapInternalKey and kv.value.len != 32: bad("a taproot internal key is 32 bytes")

proc parsePsbt*(b: openArray[byte]): Psbt =
  var r = R(b: @b)
  if b.len < 5 or @(b[0 ..< 5]) != @Magic: bad("not a PSBT (bad magic)")
  r.p = 5
  var gotTx = false
  for kv in r.readMap():
    if kv.key[0] == GUnsignedTx:
      if kv.key.len != 1: bad("PSBT_GLOBAL_UNSIGNED_TX takes no key data")
      if kv.value.len > 5 and kv.value[4] == 0x00 and kv.value[5] == 0x01:
        bad("the unsigned tx must use the non-witness serialization")
      result.tx = parseTx(kv.value)
      if result.tx.hasWitness(): bad("the unsigned tx carries a witness")
      for i in result.tx.inputs:
        if i.scriptSig.len > 0: bad("the unsigned tx has a filled scriptSig")
      gotTx = true
    else:
      result.globals.add kv
  if not gotTx: bad("no unsigned transaction")
  for _ in 0 ..< result.tx.inputs.len:
    let m = r.readMap()
    checkInput(m)
    result.inputs.add m
  for _ in 0 ..< result.tx.outputs.len:
    let m = r.readMap()
    checkOutput(m)
    result.outputs.add m
  if r.p != r.b.len: bad("trailing bytes after the PSBT")

proc parsePsbtBase64*(s: string): Psbt =
  var raw: string
  try: raw = decode(s.strip())
  except ValueError: bad("not base64")
  var b = newSeq[byte](raw.len)
  for i, c in raw: b[i] = byte(c)
  parsePsbt(b)

# ── writing ──────────────────────────────────────────────────────────────────
proc writeMap(o: var seq[byte], m: seq[PsbtKV]) =
  for kv in m:
    o.add withSize(kv.key)
    o.add withSize(kv.value)
  o.add 0x00'u8

proc serialize*(p: Psbt): seq[byte] =
  result = @Magic
  result.add withSize(@[GUnsignedTx])
  result.add withSize(p.tx.serialize(withWitness = false))
  for kv in p.globals: (result.add withSize(kv.key); result.add withSize(kv.value))
  result.add 0x00'u8
  for m in p.inputs: result.writeMap(m)
  for m in p.outputs: result.writeMap(m)

proc toBase64*(p: Psbt): string =
  var s = newString(0)
  for x in p.serialize(): s.add char(x)
  encode(s)

proc newPsbt*(unsigned: BtcTx): Psbt =
  ## a creator's PSBT: the unsigned tx (scriptSigs and witnesses stripped), empty maps
  result.tx = unsigned
  for i in result.tx.inputs.mitems: (i.scriptSig = @[]; i.witness = @[])
  result.inputs = newSeq[seq[PsbtKV]](unsigned.inputs.len)
  result.outputs = newSeq[seq[PsbtKV]](unsigned.outputs.len)

# ── typed access ─────────────────────────────────────────────────────────────
proc put(m: var seq[PsbtKV], key, value: seq[byte]) =
  for kv in m.mitems:
    if kv.key == key: (kv.value = value; return)
  m.add PsbtKV(key: key, value: value)

proc get(m: seq[PsbtKV], key: seq[byte]): (bool, seq[byte]) =
  for kv in m:
    if kv.key == key: return (true, kv.value)
  (false, @[])

proc setWitnessUtxo*(p: var Psbt, i: int, o: TxOut) = p.inputs[i].put(@[InWitnessUtxo], serializeOutput(o))
proc witnessUtxo*(p: Psbt, i: int): (bool, TxOut) =
  let (ok, v) = p.inputs[i].get(@[InWitnessUtxo])
  if not ok: return (false, TxOut())
  var r = R(b: v)
  var o: TxOut
  let a = r.take(8)
  for k in 0 ..< 8: o.value = o.value or (uint64(a[k]) shl uint64(8*k))
  o.scriptPubKey = r.take(r.cs())
  (true, o)

proc setWitnessScript*(p: var Psbt, i: int, s: seq[byte]) = p.inputs[i].put(@[InWitnessScript], s)
proc witnessScript*(p: Psbt, i: int): seq[byte] = p.inputs[i].get(@[InWitnessScript])[1]

proc addPartialSig*(p: var Psbt, i: int, pub33, sigWithType: seq[byte]) =
  if pub33.len != 33: bad("a partial signature is keyed by a 33-byte public key")
  p.inputs[i].put(@[InPartialSig] & pub33, sigWithType)
proc partialSigs*(p: Psbt, i: int): seq[(seq[byte], seq[byte])] =
  for kv in p.inputs[i]:
    if kv.key[0] == InPartialSig: result.add (kv.keyData(), kv.value)

proc setTapInternalKey*(p: var Psbt, i: int, k: seq[byte]) = p.inputs[i].put(@[InTapInternalKey], k)
proc tapInternalKey*(p: Psbt, i: int): seq[byte] = p.inputs[i].get(@[InTapInternalKey])[1]

proc setTapLeafScript*(p: var Psbt, i: int, controlBlock, script: seq[byte], leafVersion: uint8) =
  p.inputs[i].put(@[InTapLeafScript] & controlBlock, script & @[leafVersion])
proc tapLeafScripts*(p: Psbt, i: int): seq[(seq[byte], seq[byte], uint8)] =
  ## (control block, script, leaf version)
  for kv in p.inputs[i]:
    if kv.key[0] == InTapLeafScript and kv.value.len >= 1:
      result.add (kv.keyData(), kv.value[0 ..< kv.value.len - 1], kv.value[^1])

proc addTapScriptSig*(p: var Psbt, i: int, xonly, leafHash, sig: seq[byte]) =
  if xonly.len != 32 or leafHash.len != 32: bad("a tapscript signature is keyed by x-only key + leaf hash")
  p.inputs[i].put(@[InTapScriptSig] & xonly & leafHash, sig)
proc tapScriptSigs*(p: Psbt, i: int): seq[(seq[byte], seq[byte], seq[byte])] =
  ## (x-only key, leaf hash, signature)
  for kv in p.inputs[i]:
    if kv.key[0] == InTapScriptSig:
      let kd = kv.keyData()
      result.add (kd[0 ..< 32], kd[32 ..< 64], kv.value)

# ── the combiner ───────────────────────────────────────────────────────────────
proc combine*(a, b: Psbt): Psbt =
  ## BIP-174 Combiner: the union of both PSBTs' fields. Two PSBTs of different
  ## transactions never combine, and two different values under one key are refused —
  ## never silently picked.
  if a.tx.serialize(withWitness = false) != b.tx.serialize(withWitness = false):
    bad("PSBTs of different transactions cannot be combined")
  result = a
  proc merge(dst: var seq[PsbtKV], src: seq[PsbtKV]) =
    for kv in src:
      let (ok, v) = dst.get(kv.key)
      if ok and v != kv.value: bad("two different values under one PSBT key")
      if not ok: dst.add kv
  result.globals.merge(b.globals)
  for i in 0 ..< result.inputs.len: result.inputs[i].merge(b.inputs[i])
  for i in 0 ..< result.outputs.len: result.outputs[i].merge(b.outputs[i])

# ── the canonical form (invariant 5) ─────────────────────────────────────────────
proc canonicalBytes*(p: Psbt): seq[byte] =
  ## dCBOR [unsigned tx, [[amount, scriptPubKey, witnessScript, [[controlBlock, leaf, ver]]]…]]
  ## — the spend, never its encoding. An input with no prevout is refused: without its
  ## amount the fee (and a BIP-143 signature's meaning) cannot be known.
  var ins: seq[CborValue]
  for i in 0 ..< p.inputs.len:
    let (ok, prev) = p.witnessUtxo(i)
    if not ok: bad("input " & $i & " has no witness UTXO")
    var leaves: seq[CborValue]
    for (cb, s, v) in p.tapLeafScripts(i):
      leaves.add cbArray(@[cbBytes(cb), cbBytes(s), cbUint(uint64(v))])
    ins.add cbArray(@[cbUint(prev.value), cbBytes(prev.scriptPubKey), cbBytes(p.witnessScript(i)),
                      cbArray(leaves)])
  encode(cbArray(@[cbText("muster.btc.spend.v1"), cbBytes(p.tx.serialize(withWitness = false)),
                   cbArray(ins)]))
