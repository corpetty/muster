## derived-exo-a90.20 s8: a Bitcoin share is paid from the debtor's own key, in satoshis,
## never below the 546-sat dust limit; the creditor's own node confirms it only when a
## transaction pays payTo exactly the share at the network's confirmation depth; a different
## amount or address is refused and named (exo-d17).
##
## STEPPER: state = one case of share {545, 546, 150000 sat} x the output a payment makes
## {share - 1, share, share + 1} x its address {payTo, another address} x its confirmations
## {0, 5, 6} x the debtor's coins {at wpkh(their own key), only someone else's}: 108 cases,
## chained case -> case+1, on testnet (confirmation depth 6) against fake_bitcoind — a child
## process the Bitcoin seam talks to over JSON-RPC, unmodified. The rule, stated alone:
##   * the driver refuses a split iff a share is below 546 sat, and refuses payTo written
##     for another network (mainnet, regtest) whatever the share;
##   * the creditor's checkReceived confirms the payment iff it pays payTo exactly the share
##     with at least 6 confirmations; a wrong amount is refused naming both amounts, another
##     address naming that it does not pay payTo, too few confirmations naming them;
##   * a debtor with coins at their own key pays from those coins alone, every input signed
##     by that key over its BIP-143 sighash (checked here, from the raw transaction); with
##     only someone else's coins, nothing is sent.
## Run by hand (no argv), it checks all 108 with doAssert.

import std/[json, strutils, tables]
import ../../src/intents/materialization
import ../../src/coordination/parts_btc
import ../../src/wallet/btc_adapter
import ../../src/bitcoin/[tx, script, keys, sighash, bech32]
import ./split_room
import ./fake_bitcoind
import ./oracle_emit

fakeBitcoindMain()

const Testnet = "bip122:000000000933ea01ad0ee984209779ba"
const Shares = [545'u64, 546'u64, 150_000'u64]
const Deltas = [-1, 0, 1]
const Addresses = ["payTo", "other"]
const Confs = [0, 5, 6]
const Coins = ["own", "other"]
const N = 108

proc decode(k: int): tuple[share: uint64, delta: int, address: string, conf: int, coins: string] =
  (Shares[k div 36], Deltas[(k mod 36) div 12], Addresses[(k mod 12) div 6], Confs[(k mod 6) div 2], Coins[k mod 2])

proc correct(k: int): bool =
  let (share, delta, address, conf, coins) = decode(k)
  let payTo = p2wpkhAddress("tb", aliceKs.btcPubKey())
  let other = p2wpkhAddress("tb", daveKs.btcPubKey())
  # 1. the driver: dust, and payTo of another network
  let drv = newSplitDriver(BtcSplitFamily, Testnet, roster)
  proc splitWith(to: string): Effect =
    effectFromJson(splitEffectJson(Testnet, "BTC", $(3'u64 * share), alice, to,
                                   @[SplitShare(who: bob, amount: $share), SplitShare(who: carol, amount: $share)], "s8"))
  let refusal = drv.signRefusal(splitWith(payTo))
  if (share < 546'u64) != ("dust" in refusal): return false
  if share >= 546'u64 and refusal.len > 0: return false
  for foreign in [p2wpkhAddress("bc", aliceKs.btcPubKey()), p2wpkhAddress("bcrt", aliceKs.btcPubKey())]:
    if drv.signRefusal(splitWith(foreign)).len == 0: return false
  let node = startFakeNode(Testnet)
  defer: node.stop()
  let ctl = newBitcoindAdapter("testnet", node.url, "u", "p")
  let t = PartTransfer(ok: true, chain: Testnet, asset: "BTC", to: payTo, amount: $share)
  # 2. the creditor's own read of a payment that pays (address, share + delta) at `conf`
  let carolAddr = p2wpkhAddress("tb", carolKs.btcPubKey())
  let fundId = ctl.call("fake_fund", %*[carolAddr, 1_000_000]).getStr()
  let amount = uint64(int64(share) + delta)
  # built by hand, not by signedShare: the payment under test may be below dust on purpose
  let carolPub = carolKs.btcPubKey()
  var pay = BtcTx(version: 2, inputs: @[TxIn(prevout: outpointFromHex(fundId, 0), sequence: 0xfffffffd'u32)],
                  outputs: @[TxOut(value: amount, scriptPubKey: scriptPubKeyOfAddress("tb", (if address == "payTo": payTo else: other))),
                             TxOut(value: 1_000_000'u64 - amount - 1_000'u64, scriptPubKey: p2wpkhScriptPubKey(carolPub))])
  pay.inputs[0].witness = @[carolKs.signEcdsaDer(bip143Sighash(pay, 0, p2pkhScriptCode(carolPub), 1_000_000, 1)) & @[0x01'u8],
                            carolPub]
  let txid = ctl.call("sendrawtransaction", %*[toHex(pay.serialize())]).getStr()
  if conf > 0: discard ctl.call("fake_mine", %*[conf])
  let creditor = newBtcPartSeam(Testnet, newBitcoindAdapter("testnet", node.url, "u", "p"), aliceKs, feeRate = 2)
  let got = creditor.checkReceived(t, txid)
  let should = address == "payTo" and delta == 0 and conf >= 6
  if got.ok != should: return false
  if not got.ok:
    if address != "payTo" and "does not pay" notin got.detail: return false
    if address == "payTo" and delta != 0 and ($amount notin got.detail or $share notin got.detail): return false
    if address == "payTo" and delta == 0 and "confirmation" notin got.detail: return false
  # 3. the debtor pays from their own key, or not at all
  if share >= 546'u64:
    var funded: Table[string, uint64]
    let bobAddr = p2wpkhAddress("tb", bobKs.btcPubKey())
    let where = (if coins == "own": bobAddr else: other)
    for _ in 0 ..< 2:
      let id = ctl.call("fake_fund", %*[where, 400_000]).getStr()
      funded[id & ":0"] = 400_000
    let debtor = newBtcPartSeam(Testnet, newBitcoindAdapter("testnet", node.url, "u", "p"), bobKs, feeRate = 2)
    let sent = debtor.sendPart(t)
    if coins == "other": return not sent.ok
    if not sent.ok: return false
    let raw = ctl.call("getrawtransaction", %*[sent.tx, true]){"hex"}.getStr()
    let ptx = parseTx(hexToBytes(raw))
    let pub = bobKs.btcPubKey()
    var paysShare = false
    for o in ptx.outputs:
      if toHex(o.scriptPubKey) == toHex(scriptPubKeyOfAddress("tb", payTo)) and o.value == share: paysShare = true
    if not paysShare: return false
    for i, input in ptx.inputs:
      var r = input.prevout.txid
      for j in 0 ..< 16: swap(r[j], r[31 - j])
      let key = toHex(r) & ":" & $input.prevout.vout
      if key notin funded: return false                                   # only coins at wpkh(own key)
      if input.witness.len != 2 or input.witness[1] != pub: return false
      let h = bip143Sighash(ptx, i, p2pkhScriptCode(pub), funded[key], 1)
      if not ecdsaVerifyDer(input.witness[0][0 ..< ^1], h, pub): return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (share, delta, address, conf, coins) = decode(k)
    doAssert correct(k), "case " & $k & ": share " & $share & ", pays " & $(int64(share) + delta) & " to " & address &
                         " at " & $conf & " confirmation(s), debtor coins " & coins & " — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
