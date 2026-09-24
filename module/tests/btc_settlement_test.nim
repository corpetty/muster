## The Bitcoin settlement (exo-a50.2.5, Phase B) — everything short of a live node
## (the node half is btc_regtest_e2e, against a real Bitcoin Core):
##   1. buildBtcSpend turns an account's UTXOs into a btc-spend effect: largest coins
##      first until the payment and its fee are covered, the payee first, change back to
##      the account, every prevout carried, the fee declared as inputs − outputs and at
##      least the fee rate × an upper-bound vsize, the inputs declared as an external
##      read (invariant 10) — and the driver would sign it (signRefusal empty); change
##      under the dust limit goes to the fee instead; too little money raises;
##   2. settlementFor dispatches by profile: both Bitcoin families get the Bitcoin
##      settlement; a room family still gets none;
##   3. assemble admits only contributions the DRIVER accepts — a stranger's, or one
##      over another spend, is dropped; one signer twice counts once — and below k it
##      refuses, naming have / need;
##   4. at k or more it finalizes the witnesses — P2WSH: the CHECKMULTISIG dummy, then
##      exactly k signatures (+ SIGHASH_ALL) in the script's key order, then the
##      witnessScript; tapscript: one slot per key, last key first, exactly k BIP-340
##      signatures and empty slots for the rest, then the leaf and the control block —
##      every signature verifying for its key over its input's sighash;
##   5. the broadcast transaction IS the reviewed one (invariant 1): its non-witness
##      bytes equal the effect's unsigned transaction, its txid is the one the payload
##      names, and its real vsize never exceeds the estimate the fee was paid for.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, strutils, sequtils, algorithm]
import ../src/hashing/sha256
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/threshold
import ../src/drivers/btc_multisig
import ../src/bitcoin/[tx, keys, bech32]
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/coordination/intent_events
import ../src/settlement/settlement

proc secretN(n: int): seq[byte] = @(sha256(cast[seq[byte]]("muster-btc-settle-" & $n)))
let secrets = @[secretN(1), secretN(2), secretN(3)]
let pubs = secrets.mapIt(compressedPubKey(it))
let stranger = secretN(9)
let payTo = encodeSegwitAddress("bcrt", 0, hexToBytes("751e76e8199196d454941c45d1b3a323f1433bd6"))

proc utxo(n: int, value: uint64, acct: BtcAccount): BtcUtxo =
  BtcUtxo(txid: repeat(toHex(@[byte(n)]), 32), vout: uint32(n), value: value,
          scriptPubKey: toHex(acct.scriptPubKey))

proc signAs(drv: BtcMultisigDriver, e: Effect, secret: seq[byte]): Contribution =
  drv.signContribution(e, compressedPubKey(secret), proc(h: seq[byte]): seq[byte] =
    var a: array[32, byte]
    for i in 0 ..< 32: a[i] = h[i]
    if drv.account.family == P2wshFamily: ecdsaSignDer(secret, a) else: schnorrSign(secret, a))

proc vsizeOf(t: BtcTx): int =
  let weight = 3 * t.serialize(withWitness = false).len + t.serialize(withWitness = true).len
  (weight + 3) div 4

for family in [P2wshFamily, TapscriptFamily]:
  let acct = btcAccount(family, "regtest", 2, pubs)
  let drv = newBtcMultisigDriver(acct)

  # ── 1. building a spend ───────────────────────────────────────────────────────
  let coins = @[utxo(1, 30_000, acct), utxo(2, 250_000, acct), utxo(3, 120_000, acct)]
  let j = parseJson(buildBtcSpend(acct, coins, payTo, 300_000'u64, feeRate = 3))
  doAssert j["effect"].getStr() == "btc-spend"
  doAssert j["inputs"].len == 2 and j["inputs"][0]["value"].getInt() == 250_000 and
           j["inputs"][1]["value"].getInt() == 120_000, "largest first, only as many as needed: " & $j["inputs"]
  for i in j["inputs"]: doAssert i["scriptPubKey"].getStr() == toHex(acct.scriptPubKey)
  doAssert j["outputs"].len == 2
  doAssert j["outputs"][0]["address"].getStr() == payTo and j["outputs"][0]["value"].getInt() == 300_000
  doAssert j["outputs"][1]["address"].getStr() == acct.address, "change goes back to the account"
  let fee = j["fee"].getInt()
  doAssert fee == 370_000 - 300_000 - j["outputs"][1]["value"].getInt(), "fee = inputs − outputs"
  doAssert j["sources"]["inputs"].getStr() == "read", "the coins are an external read (inv 10)"
  let e = effectFromJson($j)
  doAssert drv.signRefusal(e) == "", drv.signRefusal(e)
  # change under the dust limit is not made: it goes to the fee
  let tight = parseJson(buildBtcSpend(acct, @[utxo(4, 100_600, acct)], payTo, 100_000'u64, feeRate = 1))
  doAssert tight["outputs"].len == 1 and tight["fee"].getInt() == 600, $tight
  doAssert drv.signRefusal(effectFromJson($tight)) == ""
  var raised = false
  try: discard buildBtcSpend(acct, coins, payTo, 400_000'u64, feeRate = 3)
  except BtcError: raised = true
  doAssert raised, "not enough money raises — never a spend that cannot pay"
  echo "1. ", family, ": a spend from the UTXOs — largest first, payee then change, fee declared, inputs a read OK"

  # ── 2. dispatch by profile ──────────────────────────────────────────────────────
  let relayer = Account(chain: acct.chain, form: afPublic, id: "")
  let stl = settlementFor(drv, ChainAdapter(), relayer)
  doAssert stl != nil and stl of BitcoinSettlement and stl.family == family
  doAssert settlementFor(newThresholdDriver(@[], 1), ChainAdapter(), relayer) == nil, "a room family settles nowhere"
  echo "2. ", family, ": settlementFor gives the Bitcoin settlement; a room family none OK"

  # ── 3. only accepted contributions, deduped, k enforced ─────────────────────────
  let c0 = drv.signAs(e, secrets[0])
  let c1 = drv.signAs(e, secrets[1])
  let c2 = drv.signAs(e, secrets[2])
  let foreign = drv.signContribution(e, compressedPubKey(stranger), proc(h: seq[byte]): seq[byte] =
    var a: array[32, byte]
    for i in 0 ..< 32: a[i] = h[i]
    if family == P2wshFamily: ecdsaSignDer(stranger, a) else: schnorrSign(stranger, a))
  let other = effectFromJson($tight)
  let wrongSpend = drv.signAs(other, secrets[1])
  let low = stl.assemble(drv, e, @[(contributor: "a", bytes: c0.bytes), (contributor: "a", bytes: c0.bytes),
                                   (contributor: "x", bytes: foreign.bytes), (contributor: "b", bytes: wrongSpend.bytes)])
  doAssert not low.ok and low.error == "insufficient-signatures" and low.have == 1 and low.need == 2, $low
  echo "3. ", family, ": a stranger, another spend's signature and a duplicate never count; below k refused OK"

  # ── 4. the witnesses ──────────────────────────────────────────────────────────
  let asm0 = stl.assemble(drv, e, @[(contributor: "c", bytes: c2.bytes), (contributor: "a", bytes: c0.bytes),
                                    (contributor: "b", bytes: c1.bytes)])
  doAssert asm0.ok and asm0.have == 3 and asm0.need == 2, asm0.error & " " & asm0.detail
  let payload = parseJson(asm0.tx.payload)
  let signedTx = parseTx(hexToBytes(payload["rawtx"].getStr()))
  let hashes = drv.sighashesOf(e)
  for i, inp in signedTx.inputs:
    let w = inp.witness
    if family == P2wshFamily:
      doAssert w.len == 1 + 2 + 1 and w[0].len == 0 and w[^1] == acct.witnessScript, "dummy, k sigs, script"
      var at = 0
      for key in acct.keys:          # the script's order: a signer's sig only after the previous signer's
        if at < 2 and ecdsaVerifyDer(w[1 + at][0 ..< w[1 + at].len - 1], hashes[i], key): inc at
      doAssert at == 2, "exactly k signatures, in the script's key order"
      doAssert w[1][^1] == 0x01 and w[2][^1] == 0x01, "each ends in SIGHASH_ALL"
    else:
      doAssert w.len == 3 + 2 and w[3] == acct.leafScript and w[4] == acct.controlBlock
      var nonEmpty = 0
      for slot in 0 ..< 3:
        let key = acct.keys.mapIt(xonlyOfCompressed(it))
        var sortedX = key
        sortedX.sort(proc(a, b: seq[byte]): int = cmp(toHex(a), toHex(b)))
        let sig = w[2 - slot]          # the first key is checked first: its sig is on top
        if sig.len > 0:
          doAssert sig.len == 64 and schnorrVerify(sig, hashes[i], sortedX[slot]), "slot " & $slot
          inc nonEmpty
      doAssert nonEmpty == 2, "exactly k BIP-340 signatures, empty slots for the rest"
  echo "4. ", family, ": witnesses finalized — exactly k signatures in the script's order, each verifying OK"

  # ── 5. what is broadcast is what was reviewed ──────────────────────────────────
  let (unsigned, _, _) = spendOf(e)
  doAssert signedTx.serialize(withWitness = false) == unsigned.serialize(withWitness = false)
  doAssert payload["txid"].getStr() == txidHex(signedTx)
  doAssert fee >= 3 * vsizeOf(signedTx), "the fee pays the rate for the real size: " & $fee & " vs " & $vsizeOf(signedTx)
  echo "5. ", family, ": the broadcast tx is the reviewed one; txid named; the fee covers its real vsize OK"

echo "btc_settlement_test: a spend from UTXOs, only accepted signatures, witnesses finalized, the reviewed tx broadcast — all OK"
