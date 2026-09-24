## Bitcoin primitives pinned to the official BIP test vectors (exo-a50.2.1, Phase B).
##
##   1. BIP-143 native P2WSH: the unsigned transaction round-trips, and both
##      signature hashes match (including an OP_CODESEPARATOR scriptCode); the published
##      DER signatures verify under their keys.
##   2. BIP-143 P2SH-P2WSH 6-of-6 CHECKMULTISIG (the multisig shape), SIGHASH_ALL: the
##      sighash matches, the published signature verifies, and our own RFC-6979 signature
##      is DER low-S and verifies too.
##   3. BIP-341 scriptPubKey vectors: every script tree's leaf hashes, merkle root, tweak,
##      tweaked output key, scriptPubKey, bech32m address and control blocks.
##   4. BIP-341 key-path spending: every input's signature hash matches, and the
##      published witness signature verifies under the tweaked key.
##   5. BIP-340: every signing vector reproduces its signature; every verification vector
##      gives its published result.
##   6. BIP-350: valid addresses decode and re-encode; invalid ones are refused.
##   7. The multisig scripts: sortedmulti and sortedmulti_a are order-independent and
##      shaped as BIP-383/387 say.
## Needs the secp closure — see tests/README.md.

import std/[json, os, strutils, sequtils]
import ../src/bitcoin/[tx, script, sighash, bech32, taproot, keys]

const Vectors = currentSourcePath().parentDir() / "vectors"
proc hx(s: string): seq[byte] = hexToBytes(s)

# ── 1. BIP-143 native P2WSH ────────────────────────────────────────────────────
block:
  const raw = "0100000002fe3dc9208094f3ffd12645477b3dc56f60ec4fa8e6f5d67c565d1c6b9216b36e0000000000ffffffff0815cf020f013ed6cf91d29f4202e8a58726b1ac6c79da47c23d1bee0a6925f80000000000ffffffff0100f2052a010000001976a914a30741f8145e5acadf23f751864167f32e0963f788ac00000000"
  let t = parseTx(hx(raw))
  doAssert toHex(t.serialize()) == raw, "round-trip"
  let sc1 = hx("21026dccc749adc2a9d0d89497ac511f760f45c47dc5ed9cf352a58ac706453880aeadab210255a9626aebf5e29c0e6538428ba0d1dcf6ca98ffdf086aa8ced5e0d0215ea465ac")
  let h1 = bip143Sighash(t, 1, sc1, 4900000000'u64, 3)
  doAssert toHex(h1) == "82dde6e4f1e94d02c2b7ad03d2115d691f48d064e9d52f58194a6637e4194391", toHex(h1)
  let sig1 = hx("3044022027dc95ad6b740fe5129e7e62a75dd00f291a2aeb1200b84b09d9e3789406b6c002201a9ecd315dd6a0e632ab20bbb98948bc0c6fb204f2c286963bb48517a7058e27")
  doAssert ecdsaVerifyDer(sig1, h1, hx("026dccc749adc2a9d0d89497ac511f760f45c47dc5ed9cf352a58ac706453880ae"))
  let sc2 = hx("210255a9626aebf5e29c0e6538428ba0d1dcf6ca98ffdf086aa8ced5e0d0215ea465ac")
  let h2 = bip143Sighash(t, 1, sc2, 4900000000'u64, 3)
  doAssert toHex(h2) == "fef7bd749cce710c5c052bd796df1af0d935e59cea63736268bcbe2d2134fc47", toHex(h2)
  doAssert ecdsaVerifyDer(hx("304402200de66acf4527789bfda55fc5459e214fa6083f936b430a762c629656216805ac0220396f550692cd347171cbc1ef1f51e15282e837bb2b30860dc77c8f78bc8501e5"),
                          h2, hx("0255a9626aebf5e29c0e6538428ba0d1dcf6ca98ffdf086aa8ced5e0d0215ea465"))
  doAssert not ecdsaVerifyDer(sig1, h2, hx("026dccc749adc2a9d0d89497ac511f760f45c47dc5ed9cf352a58ac706453880ae")),
    "a signature never verifies for another sighash"
  echo "1. BIP-143 native P2WSH: round-trip, both sighashes, the published signatures verify OK"

# ── 2. BIP-143 P2SH-P2WSH 6-of-6 multisig, SIGHASH_ALL ─────────────────────────
block:
  let t = parseTx(hx("010000000136641869ca081e70f394c6948e8af409e18b619df2ed74aa106c1ca29787b96e0100000000ffffffff0200e9a435000000001976a914389ffce9cd9ae88dcc0631e88a821ffdbe9bfe2688acc0832f05000000001976a9147480a33f950689af511e6e84c138dbbd3c3ee41588ac00000000"))
  let ws = hx("56210307b8ae49ac90a048e9b53357a2354b3334e9c8bee813ecb98e99a7e07e8c3ba32103b28f0c28bfab54554ae8c658ac5c3e0ce6e79ad336331f78c428dd43eea8449b21034b8113d703413d57761b8b9781957b8c0ac1dfe69f492580ca4195f50376ba4a21033400f6afecb833092a9a21cfdf1ed1376e58c5d1f47de74683123987e967a8f42103a6d48b1131e94ba04d9737d61acdaa1322008af9602b3b14862c07a1789aac162102d8b661b0b3302ee2f162b09e07a55ad5dfbe673a9f01d9f0c19617681024306b56ae")
  let h = bip143Sighash(t, 0, ws, 987654321'u64, SighashAll.uint32)
  doAssert toHex(h) == "185c0be5263dce5b4bb50a047973c1b6272bfbd0103a89444597dc40b248ee7c", toHex(h)
  let pub = hx("0307b8ae49ac90a048e9b53357a2354b3334e9c8bee813ecb98e99a7e07e8c3ba3")
  doAssert ecdsaVerifyDer(hx("304402206ac44d672dac41f9b00e28f4df20c52eeb087207e8d758d76d92c6fab3b73e2b0220367750dbbe19290069cba53d096f44530e4f98acaa594810388cf7409a1870ce"), h, pub)
  let sk = hx("730fff80e1413068a05b57d6a58261f07551163369787f349438ea38ca80fac6")
  doAssert compressedPubKey(sk) == pub
  let mine = ecdsaSignDer(sk, h)
  doAssert mine[0] == 0x30 and ecdsaVerifyDer(mine, h, pub), "our DER low-S signature verifies"
  echo "2. BIP-143 6-of-6 CHECKMULTISIG under SIGHASH_ALL: sighash matches, signatures verify OK"

# ── 3. BIP-341 scriptPubKey vectors ─────────────────────────────────────────────
proc treeOf(j: JsonNode): TapNode =
  if j.kind == JArray: tapBranch(treeOf(j[0]), treeOf(j[1]))
  else: tapLeaf(hx(j["script"].getStr()), uint8(j["leafVersion"].getInt()))

let v341 = parseJson(readFile(Vectors / "bip-0341-wallet-test-vectors.json"))
block:
  var n = 0
  for v in v341["scriptPubKey"]:
    let ik = hx(v["given"]["internalPubkey"].getStr())
    let tree = v["given"]["scriptTree"]
    var root: seq[byte]
    var leaves: seq[TapLeafInfo]
    if tree.kind != JNull:
      let m = merkle(treeOf(tree))
      root = @(m.root); leaves = m.leaves
      doAssert toHex(root) == v["intermediary"]["merkleRoot"].getStr()
      doAssert leaves.mapIt(toHex(it.leafHash)) == v["intermediary"]["leafHashes"].getElems().mapIt(it.getStr())
    doAssert toHex(tapTweak(ik, root)) == v["intermediary"]["tweak"].getStr()
    let (q, parity) = outputKey(ik, root)
    doAssert toHex(q) == v["intermediary"]["tweakedPubkey"].getStr()
    doAssert toHex(p2trScriptPubKey(q)) == v["expected"]["scriptPubKey"].getStr()
    doAssert encodeSegwitAddress("bc", 1, q) == v["expected"]["bip350Address"].getStr()
    if v["expected"].hasKey("scriptPathControlBlocks"):
      let cbs = v["expected"]["scriptPathControlBlocks"].getElems().mapIt(it.getStr())
      doAssert leaves.mapIt(toHex(controlBlock(it, ik, parity))) == cbs
    inc n
  doAssert n == 7
  echo "3. BIP-341: all ", n, " script trees — leaf hashes, root, tweak, output key, address, control blocks OK"

# ── 4. BIP-341 key-path signature hashes ────────────────────────────────────────
block:
  let k = v341["keyPathSpending"][0]
  let t = parseTx(hx(k["given"]["rawUnsignedTx"].getStr()))
  let amounts = k["given"]["utxosSpent"].getElems().mapIt(uint64(it["amountSats"].getInt()))
  let spks = k["given"]["utxosSpent"].getElems().mapIt(hx(it["scriptPubKey"].getStr()))
  var n = 0
  for s in k["inputSpending"]:
    let idx = s["given"]["txinIndex"].getInt()
    let ht = uint8(s["given"]["hashType"].getInt())
    let h = bip341Sighash(t, idx, amounts, spks, ht)
    doAssert toHex(h) == s["intermediary"]["sigHash"].getStr(), "input " & $idx
    var sig = hx(s["expected"]["witness"][0].getStr())
    if sig.len == 65: sig.setLen(64)
    let q = xonlyPubKey(hx(s["intermediary"]["tweakedPrivkey"].getStr()))
    doAssert schnorrVerify(sig, h, q), "the published witness verifies (input " & $idx & ")"
    inc n
  echo "4. BIP-341 key path: ", n, " input sighashes match, witnesses verify under the tweaked keys OK"

# ── 5. BIP-340 ─────────────────────────────────────────────────────────────────
block:
  var signed, verified = 0
  for line in readFile(Vectors / "bip-0340-test-vectors.csv").splitLines()[1 .. ^1]:
    if line.strip().len == 0: continue
    let f = line.split(',')
    let (secret, pub, aux, msg, sig, ok) = (f[1], f[2], f[3], f[4], f[5], f[6] == "TRUE")
    if secret.len > 0:
      doAssert toHex(schnorrSign(hx(secret), hx(msg), hx(aux))) == sig.toLowerAscii(), "sign vector " & f[0]
      doAssert toHex(xonlyPubKey(hx(secret))) == pub.toLowerAscii()
      inc signed
    doAssert schnorrVerify(hx(sig), hx(msg), hx(pub)) == ok, "verify vector " & f[0]
    inc verified
  echo "5. BIP-340: ", signed, " signing vectors reproduce, ", verified, " verification vectors agree OK"

# ── 6. BIP-350 addresses ─────────────────────────────────────────────────────────
block:
  for (hrp, a, spk) in [("bc", "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", "0014751e76e8199196d454941c45d1b3a323f1433bd6"),
                        ("tb", "tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7", "00201863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262"),
                        ("bc", "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y", "5128751e76e8199196d454941c45d1b3a323f1433bd6751e76e8199196d454941c45d1b3a323f1433bd6"),
                        ("bc", "BC1SW50QGDZ25J", "6002751e"),
                        ("tb", "tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c", "5120000000c4a5cad46221b2a187905e5266362b99d5e91c6ce24d165dab93e86433")]:
    doAssert toHex(scriptPubKeyOfAddress(hrp, a)) == spk, a
    let (v, p) = decodeSegwitAddress(hrp, a)
    doAssert encodeSegwitAddress(hrp, v, p) == a.toLowerAscii(), "re-encode " & a
  for (hrp, bad) in [("bc", "tc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq5zuyut"),   # not a bc address
                     ("bc", "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqh2y7hd"),   # bech32 on v1
                     ("tb", "tb1z0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqglt7rf"),   # bech32 on v2
                     ("bc", "BC1S0XLXVLHEMJA6C4DQV22UAPCTQUPFHLXM9H8Z3K2E72Q4K9HCZ7VQ54WELL"),   # bech32 on v16
                     ("bc", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh"),                        # bech32m on v0
                     ("tb", "tb1q0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq24jc47"),   # bech32m on v0
                     ("bc", "bc1pw5dgrnzv")]:                                                  # program too short
    var refused = false
    try: discard decodeSegwitAddress(hrp, bad)
    except BtcError: refused = true
    doAssert refused, "must refuse " & bad
  echo "6. BIP-350: valid addresses round-trip, invalid ones are refused OK"

# ── 7. the multisig scripts ─────────────────────────────────────────────────────
block:
  let pubs = @[hx("0307b8ae49ac90a048e9b53357a2354b3334e9c8bee813ecb98e99a7e07e8c3ba3"),
               hx("03b28f0c28bfab54554ae8c658ac5c3e0ce6e79ad336331f78c428dd43eea8449b"),
               hx("034b8113d703413d57761b8b9781957b8c0ac1dfe69f492580ca4195f50376ba4a")]
  let a = sortedMultiScript(2, pubs)
  doAssert a == sortedMultiScript(2, @[pubs[2], pubs[0], pubs[1]]), "sortedmulti ignores the listed order"
  doAssert a[0] == 0x52 and a[^2] == 0x53 and a[^1] == 0xae and a.len == 1 + 3*34 + 2
  doAssert a[2 ..< 35] == sortedKeys(pubs)[0], "lowest key first"
  let spk = p2wshScriptPubKey(a)
  doAssert spk.len == 34 and spk[0] == 0x00 and spk[1] == 0x20
  let xs = pubs.mapIt(xonlyOfCompressed(it))
  let m = multiAScript(2, xs)
  doAssert m == multiAScript(2, @[xs[1], xs[2], xs[0]]), "sortedmulti_a ignores the listed order"
  doAssert m[33] == 0xac and m[67] == 0xba and m[101] == 0xba and m[102] == 0x52 and m[103] == 0x9c and m.len == 104,
    "<K1> CHECKSIG <K2> CHECKSIGADD <K3> CHECKSIGADD 2 NUMEQUAL"
  let (q, _) = outputKey(hx(NumsH), @(tapLeafHash(m)))
  doAssert q.len == 32
  echo "7. sortedmulti / sortedmulti_a are order-independent and shaped per BIP-383/387 OK"

echo "bitcoin_primitives_test: all OK"
