## A split paid in Bitcoin, end to end on a real Bitcoin Core regtest node (exo-d17;
## docs/design/split-the-bill.md §4.9). Alice fronted a cabin; Bob and Carol each owe her a
## share, in satoshis. Each pays from their OWN key — wpkh(<their muster key>), coins read
## from the node — and Alice's client confirms each payment from its own read of the node.
##
##   infra/bitcoind/regtest.sh     # a fresh regtest chain (needs bitcoind: nix shell nixpkgs#bitcoind)
##   module/tests/run-suite.sh e2e split_btc_regtest_e2e
##
## Held: the payment each debtor's key signs spends only their own coins and pays payTo
## exactly the agreed share; the creditor refuses a payment of the wrong amount and one to
## someone else; nothing confirms before the payment is in a block; Alice's balance at payTo
## rises by exactly the shares; the split is final on all three members.

import std/[os, strutils, json, math]
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/parts
import ../src/coordination/parts_btc
import ../src/wallet/[types, btc_adapter]
import ../src/bitcoin/[tx, script, network]
import ./probes/live_room

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:18443")
let node = newBitcoindAdapter("regtest", url, "muster", "muster")
const Chain = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const Policy = "btc-split@" & Chain

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(BtcSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)

proc rpc(meth: string, params: JsonNode = newJArray(), wallet = ""): JsonNode = node.call(meth, params, wallet)

try: discard rpc("getblockcount")
except CatchableError as e: quit("no regtest node at " & url & " (" & e.msg & ") — run infra/bitcoind/regtest.sh", 2)

# the fixture: a miner wallet that funds the debtors' own wpkh addresses
try: discard rpc("createwallet", %*["miner", false, false, "", false, true])
except CatchableError: discard rpc("loadwallet", %*["miner"])
let minerAddr = rpc("getnewaddress", %*["", "bech32"], "miner").getStr()
discard rpc("generatetoaddress", %*[101, minerAddr])
proc mine() = discard rpc("generatetoaddress", %*[1, minerAddr])
proc seamFor(ks: Keystore): BtcPartSeam = newBtcPartSeam(Chain, node, ks, feeRate = 2)
for ks in [Keystore(bobKs), room3CarolKs]:
  discard rpc("sendtoaddress", %*[seamFor(ks).payerAddress(), 0.01], "miner")
mine()
let payTo = seamFor(aliceKs).payerAddress()     # Alice is paid at her own wpkh address
proc receivedAt(address: string): uint64 =
  for u in node.utxosOf(address): result += u.value
let before = receivedAt(payTo)
echo "0. Bob and Carol each hold 0.01 BTC at wpkh(<their muster key>); Alice is paid at ", payTo, " OK"

var r = newRoom3("/muster/1/split-btc-regtest/proto")
const Share = "150000"                            # 0.0015 BTC each
let effect = splitEffectJson(Chain, "BTC", "450000", alice, payTo,
                             evenShares("450000", alice, @[bob, carol]), "Cabin")
let id = liveProposeIntent(r.alice, aliceKs, splitFor, Policy, effect, int64(Now), 1,
                           account = Chain & ":" & payTo, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
doAssert liveContribute(r.bob, bobKs, splitFor, id, "", "", bindCtx(), Now) == "collecting"
doAssert liveContribute(r.carol, room3CarolKs, splitFor, id, "", "", bindCtx(), Now) == "executable"
echo "1. Alice proposes 0.0045 BTC among three; Bob and Carol agree to 0.0015 BTC each OK"

proc pay(s: CoordinationSession, ks: Keystore): string =
  let seam = seamFor(ks)
  let (outcome, pp) = liveSettlePartSend(s, ks, splitFor, id, seam, Now)
  doAssert outcome == "", outcome
  let tx = rpc("getrawtransaction", %*[pp.tx, true])
  var paysShare = false
  for o in tx{"vout"}:
    if o{"scriptPubKey"}{"address"}.getStr() == payTo and uint64(round(o{"value"}.getFloat() * 1e8)) == 150_000'u64:
      paysShare = true
  doAssert paysShare, "the payment pays payTo exactly the share: " & $tx{"vout"}
  let own = seamFor(ks).payerAddress()
  for i in tx{"vin"}:
    let prev = rpc("getrawtransaction", %*[i{"txid"}.getStr(), true])
    doAssert prev{"vout"}[i{"vout"}.getInt()]{"scriptPubKey"}{"address"}.getStr() == own,
             "only the payer's own coins are spent"
  doAssert liveSettlePartComplete(s, ks, splitFor, seam, pp).startsWith("unconfirmed"),
           "no report while the payment is only in the mempool"
  mine()
  let st = liveSettlePartComplete(s, ks, splitFor, seam, pp)
  doAssert st in ["submitted", "settling", "final"], "the report follows once it is in a block: " & st
  pp.tx

let bobTx = pay(r.bob, bobKs)
echo "2. Bob's own key paid 0.0015 BTC to Alice from his own coins: ", bobTx, " OK"

# Carol's decoys, made outside the split path: one short of the share, and the share to someone else
let aliceSeam = seamFor(aliceKs)
let hrp = networkByCaip2(Chain).hrp
proc sendRaw(ks: Keystore, to: string, sats: uint64): string =
  let signed = signedShare(ks, hrp, node.utxosOf(seamFor(ks).payerAddress()), to, sats, 2)
  let hexs = signed.serialize().toHex()
  result = rpc("sendrawtransaction", %*[hexs]).getStr()
let short = sendRaw(room3CarolKs, payTo, 149_999)
mine()
let elsewhere = sendRaw(room3CarolKs, seamFor(bobKs).payerAddress(), 150_000)
mine()
let why1 = liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, short)
doAssert why1.startsWith("unconfirmed") and "149999" in why1, why1
let why2 = liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, elsewhere)
doAssert why2.startsWith("unconfirmed") and "does not pay" in why2, why2
echo "3. one satoshi short, and the share paid to someone else: both refused, each named OK"

let carolTx = pay(r.carol, room3CarolKs)
echo "4. Carol pays her share: ", carolTx, " OK"

var confirmed: seq[string]
for _ in 0 ..< 20:
  confirmed.add liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam)
  if confirmed.len == 2: break
  sleep(200)
doAssert confirmed.len == 2, "the creditor's own node confirms both shares: " & $confirmed
for s in [r.alice, r.bob, r.carol]:
  s.poll()
for s in [r.alice, r.bob, r.carol]:
  doAssert intentState(s.roomEvents(), splitFor, id) == "final", "final on every member"
let gained = receivedAt(payTo) - before
doAssert gained == 2 * 150_000 + 149_999, "Alice received exactly the two shares (+ Carol's short decoy): " & $gained
echo "5. Alice's own node confirms both shares; final on all three members OK"

echo "split_btc_regtest_e2e: all OK"
