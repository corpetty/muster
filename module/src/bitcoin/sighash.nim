## The two signature hashes a Bitcoin multisig signs (exo-a50.2.1):
##   * BIP-143 — a P2WSH input: commits to the witnessScript (so the policy) and to THIS
##     input's amount only; the fee is implicit, so a signer must re-derive it from the
##     prevouts itself;
##   * BIP-341/342 — a taproot input: commits to EVERY input's amount and scriptPubKey,
##     and on a script path to the tapleaf being executed.
## Pinned to the BIP-143 examples and the BIP-341 wallet test vectors.

import ../hashing/sha256
import ./tx

const
  SighashDefault* = 0x00'u8   ## taproot only: ALL, with a 64-byte signature
  SighashAll* = 0x01'u8
  SighashNone* = 0x02'u8
  SighashSingle* = 0x03'u8
  SighashAnyoneCanPay* = 0x80'u8

proc bip143Sighash*(tx: BtcTx, idx: int, scriptCode: openArray[byte], amount: uint64,
                    hashType: uint32): array[32, byte] =
  ## `scriptCode` WITHOUT its length prefix (for a P2WSH multisig: the witnessScript).
  let base = hashType and 0x1f
  let acp = (hashType and 0x80) != 0
  var hashPrevouts, hashSequence, hashOutputs: array[32, byte]
  if not acp:
    var b: seq[byte]
    for i in tx.inputs: b.add serializeOutpoint(i.prevout)
    hashPrevouts = sha256d(b)
  if not acp and base != SighashSingle and base != SighashNone:
    var b: seq[byte]
    for i in tx.inputs: b.add le32(i.sequence)
    hashSequence = sha256d(b)
  if base != SighashSingle and base != SighashNone:
    var b: seq[byte]
    for o in tx.outputs: b.add serializeOutput(o)
    hashOutputs = sha256d(b)
  elif base == SighashSingle and idx < tx.outputs.len:
    hashOutputs = sha256d(serializeOutput(tx.outputs[idx]))
  var pre = le32(tx.version) & @hashPrevouts & @hashSequence
  pre.add serializeOutpoint(tx.inputs[idx].prevout)
  pre.add withSize(scriptCode)
  pre.add le64(amount)
  pre.add le32(tx.inputs[idx].sequence)
  pre.add @hashOutputs
  pre.add le32(tx.locktime)
  pre.add le32(hashType)
  sha256d(pre)

proc bip341Sighash*(tx: BtcTx, idx: int, amounts: seq[uint64], scriptPubKeys: seq[seq[byte]],
                    hashType: uint8, leafHash: seq[byte] = @[],
                    codesepPos = 0xffffffff'u32): array[32, byte] =
  ## The taproot SigMsg (BIP-341) under the "TapSighash" tag. `leafHash` empty = key path;
  ## a 32-byte tapleaf hash = a script-path spend (BIP-342 extension). No annex.
  if amounts.len != tx.inputs.len or scriptPubKeys.len != tx.inputs.len:
    raise newException(BtcError, "a taproot sighash needs every input's amount and scriptPubKey")
  let outType = (if hashType == SighashDefault: SighashAll else: hashType and 0x03)
  let acp = (hashType and 0x80) != 0
  var m: seq[byte] = @[0x00'u8, hashType]          # epoch, hash_type
  m.add le32(tx.version)
  m.add le32(tx.locktime)
  if not acp:
    var p, a, s, q: seq[byte]
    for i in tx.inputs: p.add serializeOutpoint(i.prevout)
    for v in amounts: a.add le64(v)
    for spk in scriptPubKeys: s.add withSize(spk)
    for i in tx.inputs: q.add le32(i.sequence)
    m.add @(sha256(p)); m.add @(sha256(a)); m.add @(sha256(s)); m.add @(sha256(q))
  if outType != SighashNone and outType != SighashSingle:
    var o: seq[byte]
    for x in tx.outputs: o.add serializeOutput(x)
    m.add @(sha256(o))
  let extFlag = (if leafHash.len > 0: 1'u8 else: 0'u8)
  m.add byte(extFlag * 2)                            # spend_type (no annex)
  if acp:
    m.add serializeOutpoint(tx.inputs[idx].prevout)
    m.add le64(amounts[idx])
    m.add withSize(scriptPubKeys[idx])
    m.add le32(tx.inputs[idx].sequence)
  else:
    m.add le32(uint32(idx))
  if outType == SighashSingle:
    if idx >= tx.outputs.len: raise newException(BtcError, "SIGHASH_SINGLE without a matching output")
    m.add @(sha256(serializeOutput(tx.outputs[idx])))
  if extFlag == 1:
    if leafHash.len != 32: raise newException(BtcError, "a tapleaf hash is 32 bytes")
    m.add leafHash
    m.add 0x00'u8                                    # key_version
    m.add le32(codesepPos)
  taggedHash("TapSighash", m)
