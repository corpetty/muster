## A split paid in Bitcoin (exo-d17, btc.split; docs/design/split-the-bill.md §4.9): the same
## agreement as every split, settled by each debtor's own single-key spend and confirmed by
## the creditor's own node. Held here, without a node:
##   * a debtor pays from wpkh(<their muster key>): the address derives from the keystore's
##     compressed key exactly as BIP-173's vector says, and every input of the payment is
##     signed by that key over its BIP-143 sighash (a signature the key verifies);
##   * the driver accepts a split only in BTC, on a known Bitcoin chain (CAIP-2 bip122),
##     paying an address of THAT network, with no share below the dust limit;
##   * the creditor's read confirms a payment only when an output pays payTo exactly the
##     share — a different amount, or another address, is named and refused;
##   * the kind is on the one list (btc-split@bip122:…), resolves only with a Bitcoin chain,
##     and the manifest asks for the user's own node, and the share only of the payers.
## The node itself is split_btc_regtest_e2e's. Needs secp256k1 + libsodium (the keystores).

import std/[json, strutils, sequtils]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/drivers/profile
import ../src/drivers/kinds
import ../src/drivers/registry
import ../src/drivers/split
import ../src/drivers/btc_multisig          # buildSpendFrom, spendOf
import ../src/bitcoin/[tx, script, bech32, keys, sighash, network]
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/coordination/intent_events    # effectFromJson
import ../src/coordination/accounts         # driverForPolicy
import ../src/coordination/parts_btc
import ../src/coordination/effect_summary

const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const Mainnet = "bip122:000000000019d6689c085ae165831e93"

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc filled(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc idOf(k: EncKeys): string = hexOf(k.identity().toBytes())

let creditor = encFromSeed(filled(51))
let debtorA = encFromSeed(filled(52))
let debtorB = encFromSeed(filled(53))

# ── 1. the debtor's own address: wpkh(<their key>), BIP-173's vector ──────────────
block:
  let g = hexToBytes("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
  doAssert p2wpkhAddress("bc", g) == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", p2wpkhAddress("bc", g)
  doAssert hexOf(p2wpkhScriptPubKey(g)) == "0014751e76e8199196d454941c45d1b3a323f1433bd6"
  echo "1. a debtor's address is wpkh(<their muster key>): BIP-173's vector holds OK"

# ── 2. the driver: BTC on a Bitcoin chain, an address of that network, no dust ─────
let payTo = p2wpkhAddress("bcrt", compressedPubKey(filled(7)))
let drv = newSplitDriver(BtcSplitFamily, Regtest, @[idOf(creditor), idOf(debtorA), idOf(debtorB)])
proc splitOn(chain, asset, pay: string, total = "300000", shares = evenShares("300000", idOf(creditor),
             @[idOf(debtorA), idOf(debtorB)])): Effect =
  effectFromJson(splitEffectJson(chain, asset, total, idOf(creditor), pay, shares, "cabin"))
block:
  let good = splitOn(Regtest, "BTC", payTo)
  doAssert drv.signRefusal(good) == "", drv.signRefusal(good)
  doAssert describeFor(drv, good).threshold == 3, "two debtors and the creditor"
  doAssert "BTC" in drv.signRefusal(splitOn(Regtest, "ETH", payTo)), "a Bitcoin split is paid in BTC"
  let mainnetAddr = p2wpkhAddress("bc", compressedPubKey(filled(7)))
  doAssert drv.signRefusal(splitOn(Regtest, "BTC", mainnetAddr)).len > 0, "payTo must be a regtest address"
  doAssert drv.signRefusal(splitOn(Regtest, "BTC", "not-an-address")).len > 0
  let dust = splitOn(Regtest, "BTC", payTo, "1000", evenShares("1000", idOf(creditor), @[idOf(debtorA)]))
  doAssert "dust" in drv.signRefusal(dust), "a share below 546 sat can never be paid: " & drv.signRefusal(dust)
  doAssert drv.signRefusal(splitOn(Mainnet, "BTC", mainnetAddr)).len > 0, "the policy's chain, never another"
  let t = drv.partTransfer(good, partName(idOf(debtorA)))
  doAssert t.ok and t.chain == Regtest and t.asset == "BTC" and t.to == payTo and t.amount == "100000"
  echo "2. btc.split: BTC on its own Bitcoin chain, an address of that network, no dust share OK"

# ── 3. kinds, registry, profile, manifest ────────────────────────────────────────
block:
  doAssert isKnownKind("btc-split") and kindInfo("btc-split").family == BtcSplitFamily
  let build = proc(policy: string): Driver =
    let (k, chain) = splitPolicy(policy)
    if k == "btc-split": newSplitDriver(BtcSplitFamily, chain) else: newUnsupportedDriver(policy)
  doAssert driverForPolicy("btc-split@" & Regtest, @[], build) of SplitDriver
  doAssert not driverForPolicy("btc-split@eip155:1", @[], build).supported(), "not a Bitcoin chain"
  doAssert newDriver("btc-split", %*{"chain": Regtest}).profile().family == BtcSplitFamily
  let p = drv.profile()
  doAssert p.declared and p.locus == loEach and p.settlement == "bitcoin" and p.chain == Regtest
  doAssert profileFailures(p, drv.describe()).len == 0, $profileFailures(p, drv.describe())
  let m = drv.manifest(splitOn(Regtest, "BTC", payTo))
  doAssert m.requirements.anyIt(it.kind == rqEnvironment and it.name == Regtest)
  doAssert m.requirements.anyIt(it.kind == rqInfra and it.name == "bitcoind-rpc"), "the user's own node"
  doAssert m.requirements.anyIt(it.kind == rqAsset and it.party == rpPayer and it.needs.target == Regtest & "/BTC")
  for f in ["payer", "payee", "amount"]:
    doAssert m.discloses.anyIt(it.field == f and it.to == obChainObserver), "Bitcoin: " & f & " is public"
  doAssert consistent(m, splitOn(Regtest, "BTC", payTo)), $consistencyFailures(m, splitOn(Regtest, "BTC", payTo))
  echo "3. btc-split: one kind, resolves only on a Bitcoin chain; profile and manifest say so OK"

# ── 4. paying: every input signed by the debtor's own key, over its BIP-143 sighash ──
block:
  let ks = newInMemoryKeystore(filled(0x61), filled(0x62))
  let pub = ks.btcPubKey()
  let spk = p2wpkhScriptPubKey(pub)
  let mine = p2wpkhAddress("bcrt", pub)
  let utxos = @[BtcUtxo(txid: repeat("aa", 32), vout: 0, value: 60_000, scriptPubKey: hexOf(spk)),
                BtcUtxo(txid: repeat("bb", 32), vout: 1, value: 70_000, scriptPubKey: hexOf(spk)),
                BtcUtxo(txid: repeat("cc", 32), vout: 2, value: 999_999,
                        scriptPubKey: hexOf(p2wpkhScriptPubKey(compressedPubKey(filled(9)))))]   # not mine
  let t = signedShare(ks, "bcrt", utxos, payTo, 100_000, feeRate = 2)
  doAssert t.inputs.len == 2, "only the debtor's own coins are spent"
  doAssert t.outputs[0].scriptPubKey == scriptPubKeyOfAddress("bcrt", payTo) and t.outputs[0].value == 100_000
  var amounts: seq[uint64]
  for i in t.inputs:
    for u in utxos:
      if outpointFromHex(u.txid, u.vout) == i.prevout: amounts.add u.value
  for i, input in t.inputs:
    doAssert input.witness.len == 2 and input.witness[1] == pub, "wpkh witness: [signature, key]"
    let sigDer = input.witness[0][0 ..< ^1]
    doAssert input.witness[0][^1] == 0x01'u8, "SIGHASH_ALL"
    let h = bip143Sighash(t, i, p2pkhScriptCode(pub), amounts[i], 1)
    doAssert ecdsaVerifyDer(sigDer, h, pub), "input " & $i & " is signed by the debtor's key"
  doAssert t.outputs.len == 2 and t.outputs[1].scriptPubKey == spk, "change goes back to the debtor: " & mine
  echo "4. a share is paid from the debtor's own coins, every input signed by their key OK"

# ── 5. the creditor's read: an output paying payTo exactly the share ──────────────
block:
  let paySpk = hexOf(scriptPubKeyOfAddress("bcrt", payTo))
  let vout = %*[{"value": 0.001, "n": 0, "scriptPubKey": {"hex": paySpk}},
                {"value": 0.5, "n": 1, "scriptPubKey": {"hex": "0014" & repeat("11", 20)}}]
  doAssert matchBtcPayment(vout, paySpk, "100000") == "", matchBtcPayment(vout, paySpk, "100000")
  let short = matchBtcPayment(vout, paySpk, "100001")
  doAssert "100000" in short and "100001" in short, "the amount it pays and the share, named: " & short
  let elsewhere = matchBtcPayment(%*[{"value": 0.001, "n": 0, "scriptPubKey": {"hex": "0014" & repeat("22", 20)}}],
                                  paySpk, "100000")
  doAssert "does not pay" in elsewhere, elsewhere
  echo "5. the creditor confirms only an output paying payTo exactly the share OK"

# ── 6. the words read in BTC's own decimals (8), never ETH's 18 ─────────────────
block:
  let sm = effectSummary(splitEffectJson(Regtest, "BTC", "450000", idOf(creditor), payTo,
                         evenShares("450000", idOf(creditor), @[idOf(debtorA), idOf(debtorB)]), "cabin"))
  doAssert "0.0045 BTC" in sm.text, "a Bitcoin split reads in BTC: " & sm.text
  doAssert sm.amount == "450000" and sm.unit == "sat", "the raw amount stays in satoshis: " & sm.unit
  echo "6. a Bitcoin split reads 0.0045 BTC; its raw amount stays in satoshis OK"

echo "split_btc_test: all OK"
