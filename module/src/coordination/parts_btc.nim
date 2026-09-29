## A part paid and read on Bitcoin (exo-d17; docs/design/split-the-bill.md §4.9): the
## PartSeam a split's btc.split family settles through. The payer pays from their OWN key —
## wpkh(<their muster key>), the keystore's secp256k1 authorization key, which never leaves
## it — spending coins read from THEIR OWN node (scantxoutset), and the node broadcasts. The
## creditor reads a reported transaction from THEIR OWN node (invariant 8) and confirms it
## only when an output pays payTo exactly the share, at the network's confirmation depth
## (1 on regtest, 6 elsewhere) — observed, never asserted.
##
## Nothing on the chain says which split a payment settles: the link lives in the room,
## and a payment's inputs name its payer to anyone reading the chain (the manifest says so).

import std/[json, strutils, math]
import ../crypto/keystore
import ../intents/materialization   # PartTransfer
import ../wallet/[types, btc_adapter]
import ../bitcoin/[tx, script, bech32, sighash, network]
import ../drivers/btc_multisig      # buildSpendFrom, spendOf
import ./intent_events              # effectFromJson
import ./parts

const P2wpkhInputWeight* = 4 * 41 + (1 + (1 + 73) + (1 + 33))
  ## An upper bound, in weight units, for one P2WPKH input: the outpoint, an empty
  ## scriptSig and the sequence at 4 WU a byte; the witness (a DER signature at its
  ## 72-byte maximum + the hashtype, and the 33-byte key) at 1.

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc signedShare*(ks: Keystore, hrp: string, utxos: seq[BtcUtxo], payTo: string, amount: uint64,
                  feeRate: int): BtcTx =
  ## The payment of one share: `amount` sat to `payTo` from the payer's own coins — only
  ## those at wpkh(<their key>) — change back to them unless it would be dust, every input
  ## signed by their key (DER, SIGHASH_ALL) over its BIP-143 sighash. Raises BtcError when
  ## the coins cannot pay the share and its fee.
  let pub = ks.btcPubKey()
  let spk = p2wpkhScriptPubKey(pub)
  let spend = buildSpendFrom(spk, p2wpkhAddress(hrp, pub), P2wpkhInputWeight, utxos, payTo, amount, feeRate)
  var (t, amounts, _) = spendOf(effectFromJson(spend))
  let code = p2pkhScriptCode(pub)
  for i in 0 ..< t.inputs.len:
    let h = bip143Sighash(t, i, code, amounts[i], 1)
    t.inputs[i].witness = @[ks.signEcdsaDer(h) & @[0x01'u8], pub]
  t

proc satsOf(v: JsonNode): uint64 =
  ## A node's BTC amount as satoshis: ×1e8, rounded — exact for every amount Bitcoin can
  ## hold, and never on a signing path (invariant 5).
  if v == nil or v.kind notin {JFloat, JInt}: raise newException(BtcError, "not an amount: " & $v)
  let f = (if v.kind == JInt: float(v.getInt()) else: v.getFloat())
  if f < 0: raise newException(BtcError, "a negative amount: " & $v)
  uint64(round(f * 1e8))

proc matchBtcPayment*(vout: JsonNode, paySpkHex, share: string): string =
  ## "" when one of a transaction's outputs (the node's decoded `vout`) pays the script
  ## `paySpkHex` exactly `share` sat; otherwise what it does pay, named.
  var paid: seq[string]
  if vout != nil and vout.kind == JArray:
    for o in vout:
      if o{"scriptPubKey"}{"hex"}.getStr().toLowerAscii() != paySpkHex.toLowerAscii(): continue
      let sats = $satsOf(o{"value"})
      if sats == share: return ""
      paid.add sats
  if paid.len == 0: "the transaction does not pay payTo"
  else: "it pays payTo " & paid.join(" + ") & " sat; the share is " & share & " sat"

type BtcPartSeam* = ref object of PartSeam
  chain*: string              ## CAIP-2, "bip122:<genesis prefix>"
  node*: BitcoindAdapter      ## this member's own node
  ks*: Keystore
  feeRate*: int               ## sat/vB; 0 = ask the node

proc newBtcPartSeam*(chain: string, node: BitcoindAdapter, ks: Keystore, feeRate = 0): BtcPartSeam =
  BtcPartSeam(chain: chain, node: node, ks: ks, feeRate: feeRate)

proc payerAddress*(s: BtcPartSeam): string =
  ## Where this member's own coins must be to pay a share: wpkh(<their key>).
  p2wpkhAddress(networkByCaip2(s.chain).hrp, s.ks.btcPubKey())

proc refuse(s: BtcPartSeam, t: PartTransfer): string =
  if t.chain != s.chain: return "this node serves " & s.chain & ", the part settles on " & t.chain
  if t.asset != "BTC": return "a Bitcoin share is paid in BTC (asked: " & t.asset & ")"
  # the node must serve the chain agreed: never pay, nor confirm, through another one
  try:
    let genesis = s.node.call("getblockhash", %*[0]).getStr()
    if genesis.len != 64 or "bip122:" & genesis[0 ..< 32] != s.chain:
      return "your node serves bip122:" & genesis[0 ..< min(32, genesis.len)] & ", the part settles on " & s.chain
  except CatchableError as e:
    return "could not reach your node: " & e.msg
  ""

proc rateOf(s: BtcPartSeam): int =
  ## The fee rate: the member's own setting, else the node's estimate for six blocks, else
  ## the node's minimum relay fee — always read, never invented.
  if s.feeRate > 0: return s.feeRate
  try:
    let r = s.node.call("estimatesmartfee", %*[6])
    if r != nil and r{"feerate"} != nil: return max(1, int(satsOf(r{"feerate"}) div 1000))
  except CatchableError: discard
  let n = s.node.call("getnetworkinfo")
  max(1, int((satsOf(n{"relayfee"}) + 999) div 1000))

method sendPart*(s: BtcPartSeam, t: PartTransfer): tuple[ok: bool, tx, detail: string] =
  let why = s.refuse(t)
  if why.len > 0: return (false, "", why)
  try:
    let hrp = networkByCaip2(s.chain).hrp
    let coins = s.node.utxosOf(s.payerAddress())
    let signed = signedShare(s.ks, hrp, coins, t.to, parseBiggestUInt(t.amount).uint64, s.rateOf())
    let r = s.node.submit(PreparedTx(chain: s.chain, to: t.to,
                                     payload: $(%*{"rawtx": hexOf(signed.serialize()), "txid": signed.txidHex()})),
                          s.ks)
    (true, r.id, "")
  except CatchableError as e:
    (false, "", e.msg)

method partLanded*(s: BtcPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  try:
    let r = s.node.call("getrawtransaction", %*[tx, true])
    if r{"confirmations"}.getInt(0) >= 1: (true, "")
    else: (false, tx & " is in the mempool, not yet in a block")
  except CatchableError as e:
    (false, "your node does not know " & tx & " yet: " & e.msg)

method checkReceived*(s: BtcPartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  ## The creditor's own read of a reported payment: on this chain, an output paying payTo
  ## exactly the share, at this network's confirmation depth — each mismatch named.
  let why = s.refuse(t)
  if why.len > 0: return (false, why)
  try:
    let hrp = networkByCaip2(s.chain).hrp
    let r = s.node.call("getrawtransaction", %*[tx, true])
    let m = matchBtcPayment(r{"vout"}, hexOf(scriptPubKeyOfAddress(hrp, t.to)), t.amount)
    if m.len > 0: return (false, tx & ": " & m)
    let conf = r{"confirmations"}.getInt(0)
    if conf < s.node.finalDepth:
      return (false, tx & " has " & $conf & " confirmation(s); it is final at " & $s.node.finalDepth)
    (true, "")
  except CatchableError as e:
    (false, "your node cannot read " & tx & ": " & e.msg)
