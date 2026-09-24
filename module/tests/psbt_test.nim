## PSBT (BIP-174 v0 + BIP-371 taproot fields) — the format signers outside muster speak
## (exo-a50.2.2, Phase B). Held here:
##   1. every BIP-174 and BIP-371 INVALID test vector is refused; every VALID one parses
##      and re-serializes byte-for-byte (unknown fields preserved);
##   2. a 2-of-3 P2WSH spend: witness UTXO + witnessScript + partial signatures survive a
##      round trip and read back per input;
##   3. a tapscript spend: the leaf script + control block and per-(key, leaf) script
##      signatures survive a round trip;
##   4. combining two signers' PSBTs unions their signatures; two different values under
##      the same key are refused, never silently picked;
##   5. muster never hashes PSBT bytes (invariant 5): the canonical form is dCBOR of the
##      unsigned tx + each input's prevout + spending script, identical across encodings
##      that reorder fields or add proprietary / xpub / derivation data — and different
##      the moment the transaction or a prevout differs.
## Needs nothing beyond the Nim stdlib + the bitcoin module.

import std/[json, os, strutils, sequtils, base64]
import ../src/bitcoin/[tx, script, taproot, psbt]

const Vectors = currentSourcePath().parentDir() / "vectors"
let pv = parseJson(readFile(Vectors / "psbt-test-vectors.json"))

# ── 1. the BIP vectors ──────────────────────────────────────────────────────────
block:
  var refused, parsed = 0
  for bip in ["bip174", "bip371"]:
    for c in pv[bip]["invalid"]:
      var ok = false
      try: discard parsePsbt(hexToBytes(c["hex"].getStr()))
      except PsbtError, BtcError: ok = true
      doAssert ok, bip & " must refuse: " & c["case"].getStr()
      inc refused
    for c in pv[bip]["valid"]:
      let b = hexToBytes(c["hex"].getStr())
      let p = parsePsbt(b)
      doAssert p.serialize() == b, bip & " must round-trip: " & c["case"].getStr()
      doAssert parsePsbtBase64(p.toBase64()).serialize() == b
      inc parsed
  doAssert refused == 31 and parsed == 20, $refused & " / " & $parsed
  echo "1. all ", refused, " invalid BIP-174/371 vectors refused; all ", parsed, " valid ones round-trip byte-for-byte OK"

# ── a 2-of-3 P2WSH spend ─────────────────────────────────────────────────────────
let keys = @["0307b8ae49ac90a048e9b53357a2354b3334e9c8bee813ecb98e99a7e07e8c3ba3",
             "03b28f0c28bfab54554ae8c658ac5c3e0ce6e79ad336331f78c428dd43eea8449b",
             "034b8113d703413d57761b8b9781957b8c0ac1dfe69f492580ca4195f50376ba4a"].mapIt(hexToBytes(it))
let ws = sortedMultiScript(2, keys)
let prev = TxOut(value: 100_000, scriptPubKey: p2wshScriptPubKey(ws))
var unsigned = BtcTx(version: 2, locktime: 0)
unsigned.inputs.add TxIn(prevout: outpointFromHex(repeat("ab", 32), 1), sequence: 0xfffffffd'u32)
unsigned.outputs.add TxOut(value: 99_000, scriptPubKey: hexToBytes("0014751e76e8199196d454941c45d1b3a323f1433bd6"))

block:
  var p = newPsbt(unsigned)
  p.setWitnessUtxo(0, prev)
  p.setWitnessScript(0, ws)
  let sigA = hexToBytes("3044022027dc95ad6b740fe5129e7e62a75dd00f291a2aeb1200b84b09d9e3789406b6c002201a9ecd315dd6a0e632ab20bbb98948bc0c6fb204f2c286963bb48517a7058e2701")
  let sigB = hexToBytes("304402200de66acf4527789bfda55fc5459e214fa6083f936b430a762c629656216805ac0220396f550692cd347171cbc1ef1f51e15282e837bb2b30860dc77c8f78bc8501e501")
  p.addPartialSig(0, keys[0], sigA)
  p.addPartialSig(0, keys[2], sigB)
  let q = parsePsbtBase64(p.toBase64())
  doAssert q.serialize() == p.serialize()
  doAssert q.witnessUtxo(0) == (true, prev)
  doAssert q.witnessScript(0) == ws
  let sigs = q.partialSigs(0)
  doAssert sigs.len == 2 and (keys[0], sigA) in sigs and (keys[2], sigB) in sigs
  doAssert q.tx.inputs[0].scriptSig.len == 0 and not q.tx.hasWitness(), "the global tx stays unsigned"
  echo "2. a 2-of-3 P2WSH spend: witness UTXO, witnessScript and two partial signatures round-trip OK"

# ── 3. a tapscript spend ──────────────────────────────────────────────────────────
block:
  let xs = keys.mapIt(it[1 .. ^1])
  let leaf = multiAScript(2, xs)
  let m = merkle(tapLeaf(leaf))
  let (q32, parity) = outputKey(hexToBytes(NumsH), @(m.root))
  var t = unsigned
  let tprev = TxOut(value: 100_000, scriptPubKey: p2trScriptPubKey(q32))
  var p = newPsbt(t)
  p.setWitnessUtxo(0, tprev)
  p.setTapInternalKey(0, hexToBytes(NumsH))
  let cb = controlBlock(m.leaves[0], hexToBytes(NumsH), parity)
  p.setTapLeafScript(0, cb, leaf, TapscriptLeafVersion)
  let s1 = newSeq[byte](64)
  var s2 = newSeq[byte](64); s2[0] = 7
  p.addTapScriptSig(0, xs[0], @(m.leaves[0].leafHash), s1)
  p.addTapScriptSig(0, xs[1], @(m.leaves[0].leafHash), s2)
  let r = parsePsbt(p.serialize())
  doAssert r.tapLeafScripts(0) == @[(cb, leaf, TapscriptLeafVersion)]
  doAssert r.tapInternalKey(0) == hexToBytes(NumsH)
  let ts = r.tapScriptSigs(0)
  doAssert ts.len == 2 and (xs[1], @(m.leaves[0].leafHash), s2) in ts
  echo "3. a tapscript spend: leaf script + control block and per-(key, leaf) signatures round-trip OK"

# ── 4. combining signers ──────────────────────────────────────────────────────────
block:
  var a = newPsbt(unsigned)
  a.setWitnessUtxo(0, prev); a.setWitnessScript(0, ws)
  var b = a
  let sa = hexToBytes("3044022027dc95ad6b740fe5129e7e62a75dd00f291a2aeb1200b84b09d9e3789406b6c002201a9ecd315dd6a0e632ab20bbb98948bc0c6fb204f2c286963bb48517a7058e2701")
  let sb = hexToBytes("304402200de66acf4527789bfda55fc5459e214fa6083f936b430a762c629656216805ac0220396f550692cd347171cbc1ef1f51e15282e837bb2b30860dc77c8f78bc8501e501")
  a.addPartialSig(0, keys[0], sa)
  b.addPartialSig(0, keys[1], sb)
  let c = combine(a, b)
  doAssert c.partialSigs(0).len == 2
  var other = unsigned
  other.outputs[0].value = 1
  var refused = false
  try: discard combine(a, newPsbt(other))
  except PsbtError: refused = true
  doAssert refused, "PSBTs of different transactions never combine"
  var clash = newPsbt(unsigned)
  clash.setWitnessUtxo(0, prev); clash.setWitnessScript(0, ws)
  clash.addPartialSig(0, keys[0], sb)
  refused = false
  try: discard combine(a, clash)
  except PsbtError: refused = true
  doAssert refused, "two different signatures under one key are refused, not picked"
  echo "4. combining unions signatures; a different transaction or a clashing value is refused OK"

# ── 5. the canonical form ─────────────────────────────────────────────────────────
block:
  var a = newPsbt(unsigned)
  a.setWitnessUtxo(0, prev); a.setWitnessScript(0, ws)
  var b = newPsbt(unsigned)
  b.setWitnessScript(0, ws); b.setWitnessUtxo(0, prev)            # other field order
  b.inputs[0].add PsbtKV(key: @[0xfc'u8, 3, byte('m'), byte('s'), byte('t')], value: @[1'u8])   # proprietary
  b.addPartialSig(0, keys[1], hexToBytes("304402200de66acf4527789bfda55fc5459e214fa6083f936b430a762c629656216805ac0220396f550692cd347171cbc1ef1f51e15282e837bb2b30860dc77c8f78bc8501e501"))
  doAssert a.serialize() != b.serialize()
  doAssert canonicalBytes(a) == canonicalBytes(b), "one spend, one canonical form, however it was encoded or signed"
  var c = newPsbt(unsigned)
  c.setWitnessUtxo(0, TxOut(value: 100_001, scriptPubKey: prev.scriptPubKey)); c.setWitnessScript(0, ws)
  doAssert canonicalBytes(c) != canonicalBytes(a), "a different prevout amount is a different spend"
  var missing = newPsbt(unsigned)
  var refused = false
  try: discard canonicalBytes(missing)
  except PsbtError: refused = true
  doAssert refused, "an input with no prevout cannot be canonicalized (its fee is unknowable)"
  echo "5. the canonical form ignores encoding, order and extra fields — never the spend itself OK"

echo "psbt_test: all OK"
