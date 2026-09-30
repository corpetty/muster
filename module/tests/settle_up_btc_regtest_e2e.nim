## Settle up in Bitcoin, end to end on a real Bitcoin Core regtest node (exo-a90.18;
## docs/design/split-the-bill.md §4.11). Alice fronted dinner (Bob and Carol owe her 300,000
## sat each); Bob fronted the taxi (Alice and Carol owe him 200,000 each). Settled up, Carol
## pays Alice 400,000 and Bob 100,000 — two payments from her own wpkh key, sent back to back
## before either is in a block.
##
##   infra/bitcoind/regtest.sh     # a fresh regtest chain (needs bitcoind: nix shell nixpkgs#bitcoind)
##   module/tests/run-suite.sh e2e settle_up_btc_regtest_e2e
##
## Held: the second payment never spends a coin the first already spent in the mempool — it
## pays from another of Carol's coins, so both are accepted; each pays its recipient's own
## address exactly its net amount; each recipient's own node confirms its payment at depth;
## the settle-up is final, and once each creditor marks what it covered received, both splits
## are final on every member. And (exo-a90.23) a payment the chain can no longer land is
## known as such: in the mempool it is not gone; replaced by another spend of its coin, it is.

import std/[os, strutils, json, math, sequtils, algorithm]
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
import ../src/coordination/settle_up
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

try: discard rpc("createwallet", %*["miner", false, false, "", false, true])
except CatchableError: discard rpc("loadwallet", %*["miner"])
let minerAddr = rpc("getnewaddress", %*["", "bech32"], "miner").getStr()
discard rpc("generatetoaddress", %*[101, minerAddr])
proc mine() = discard rpc("generatetoaddress", %*[1, minerAddr])
proc seamFor(ks: Keystore): BtcPartSeam = newBtcPartSeam(Chain, node, ks, feeRate = 2)
# Carol holds two separate coins: enough for either payment alone, not both from one
let carolAddr = seamFor(room3CarolKs).payerAddress()
for _ in 0 ..< 2: discard rpc("sendtoaddress", %*[carolAddr, 0.006], "miner")
mine()
let payA = seamFor(aliceKs).payerAddress()
let payB = seamFor(bobKs).payerAddress()
proc receivedAt(address: string): uint64 =
  for u in node.utxosOf(address): result += u.value
let beforeA = receivedAt(payA)
let beforeB = receivedAt(payB)
doAssert node.utxosOf(carolAddr).len == 2
echo "0. Carol holds two coins of 0.006 BTC at wpkh(<her muster key>); Alice and Bob are paid at their own OK"

var r = newRoom3("/muster/1/settle-up-btc-regtest/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
var seqNo = 0'u64
proc propose(s: CoordinationSession, ks: Keystore, effect, payTo: string): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, Policy, effect, int64(Now), seqNo, account = Chain & ":" & payTo, ttlSec = Ttl)

let dinner = r.alice.propose(aliceKs, splitEffectJson(Chain, "BTC", "900000", alice, payA,
                              evenShares("900000", alice, @[bob, carol]), "Dinner"), payA)
let taxi = r.bob.propose(bobKs, splitEffectJson(Chain, "BTC", "600000", bob, payB,
                          evenShares("600000", bob, @[alice, carol]), "Taxi"), payB)
discard agree(r.bob, bobKs, dinner)
doAssert agree(r.carol, room3CarolKs, dinner) == "executable"
discard agree(r.alice, aliceKs, taxi)
doAssert agree(r.carol, room3CarolKs, taxi) == "executable"
sync()
let open = openParts(r.alice.roomEvents(), splitFor, Chain, "BTC", Now)
doAssert open.len == 4, $open.len
let net = netTransfers(open)
doAssert net.len == 2 and net.allIt(it.frm == carol), $net.len
let su = r.alice.propose(aliceKs, settleUpEffectJson(Chain, "BTC", open, net, "Lisbon"), payA)
doAssert su.startsWith("0x"), su
discard agree(r.bob, bobKs, su)
doAssert agree(r.carol, room3CarolKs, su) == "executable"
echo "1. two splits in BTC, settled up: Carol pays Alice 400,000 sat and Bob 100,000 OK"

# ── 2. Carol pays both, back to back, before either is in a block ────────────────
let seam = seamFor(room3CarolKs)
let (o1, pp1) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, seam, Now)
doAssert o1 == "", o1
let (o2, pp2) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, seam, Now, inFlight = @[pp1])
doAssert o2 == "", "the second payment is sent while the first is in the mempool: " & o2
let mem = rpc("getrawmempool")
doAssert pp1.tx in mem.mapIt(it.getStr()) and pp2.tx in mem.mapIt(it.getStr()), "both accepted: " & $mem
proc inputsOf(tx: string): seq[string] =
  for i in rpc("getrawtransaction", %*[tx, true]){"vin"}: result.add i{"txid"}.getStr() & ":" & $i{"vout"}.getInt()
for i in inputsOf(pp1.tx): doAssert i notin inputsOf(pp2.tx), "no coin spent twice: " & i
echo "2. Carol's two payments, back to back: each from its own coin, both in the mempool OK"

proc paysExactly(tx, to: string, sats: uint64): bool =
  for o in rpc("getrawtransaction", %*[tx, true]){"vout"}:
    if o{"scriptPubKey"}{"address"}.getStr() == to and uint64(round(o{"value"}.getFloat() * 1e8)) == sats: return true
doAssert paysExactly(pp1.tx, pp1.transfer.to, parseBiggestUInt(pp1.transfer.amount).uint64)
doAssert paysExactly(pp2.tx, pp2.transfer.to, parseBiggestUInt(pp2.transfer.amount).uint64)
doAssert @[pp1.transfer.amount, pp2.transfer.amount].sorted() == @["100000", "400000"], "each net amount once"

# ── 3. mined; reported; each recipient's own node confirms; everything final ──────
mine()
for pp in [pp1, pp2]:
  doAssert liveSettlePartComplete(r.carol, room3CarolKs, splitFor, seam, pp) in ["submitted", "settling", "final"]
sync()
var confirmed = 0
for _ in 0 ..< 20:
  confirmed += liveConfirmParts(r.alice, aliceKs, splitFor, seamFor(aliceKs)).len
  confirmed += liveConfirmParts(r.bob, bobKs, splitFor, seamFor(bobKs)).len
  if confirmed == 2: break
  sleep(200)
doAssert confirmed == 2, "each recipient's own node confirms its payment: " & $confirmed
sync()
doAssert intentState(r.carol.roomEvents(), splitFor, su) == "final"
discard settleCovered(r.alice, aliceKs, splitFor, seamFor(aliceKs))
discard settleCovered(r.bob, bobKs, splitFor, seamFor(bobKs))
sync()
for s in [r.alice, r.bob, r.carol]:
  doAssert intentState(s.roomEvents(), splitFor, dinner) == "final" and intentState(s.roomEvents(), splitFor, taxi) == "final"
doAssert receivedAt(payA) - beforeA == 400_000 and receivedAt(payB) - beforeB == 100_000,
         "Alice +400,000 and Bob +100,000 sat exactly"
echo "3. both confirmed from each recipient's own node; the settle-up and both splits final on all three OK"

# ── 4. partGone: a payment is gone only once another transaction spent its coin ───────
block:
  let t = PartTransfer(ok: true, chain: Chain, asset: "BTC", to: payA, amount: "50000")
  let sent = seam.sendPart(t)
  doAssert sent.ok, sent.detail
  let p = PendingPart(tx: sent.tx, transfer: t, spends: seam.lastSpends())
  doAssert p.spends.len >= 1, "the coins it spends are kept with it"
  doAssert not seam.partGone(t, p).gone, "in the mempool: it may still land"
  # the same coin, spent again at a higher fee back to Carol herself: it replaces the payment
  let coin = p.spends[0]
  let c = coin.rfind(':')
  var coins: seq[BtcUtxo]
  for u in node.utxosOf(carolAddr):
    if u.txid == coin[0 ..< c] and $u.vout == coin[c + 1 .. ^1]: coins.add u
  doAssert coins.len == 1, "the payment's coin is still confirmed-unspent: " & coin
  let replacement = signedShare(room3CarolKs, networkByCaip2(Chain).hrp, coins, carolAddr, 40_000, feeRate = 30)
  discard rpc("sendrawtransaction", %*[replacement.serialize().toHex()])
  let why = seam.partGone(t, p)
  doAssert why.gone, "replaced by another spend of its coin, it can never land: " & why.detail
  mine()
  doAssert seam.partGone(t, p).gone, "and still, once the replacement is mined"
  echo "4. partGone: in the mempool it may still land; once another spend takes its coin, it never can OK"

echo "settle_up_btc_regtest_e2e: all OK"
