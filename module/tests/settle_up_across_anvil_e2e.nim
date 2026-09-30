## Settle up across assets and chains, end to end on a live EVM chain (exo-a90.17;
## docs/design/split-the-bill.md §4.13). Three splits in three assets on two chains:
##   * dinner in ETH on anvil: Alice fronted, Bob and Carol owe her 0.3 ETH each;
##   * a taxi in the test token (MTD, 6 decimals) on anvil: Bob fronted, Alice and Carol owe
##     him 0.2 MTD each;
##   * a hotel in BTC on regtest: Carol fronted, Alice and Bob owe her 0.02 BTC each.
## Settled up in ETH on anvil at Alice's rates (1 MTD = 0.5 ETH, 1 BTC = 20 ETH): Alice is up
## 0.1 ETH, Carol 0.4, Bob down 0.5 — so Bob pays Carol 0.4 ETH and Alice 0.1 ETH, and nobody
## else pays anything. Carol is owed on no split on anvil, so she is paid at the Ethereum address
## she shared into the room, and her own client vouches for it by agreeing.
##
##   anvil --port 8548 &   # any fresh anvil (chain id 31337, the default funded accounts)
##   TEST_ARGS=http://127.0.0.1:8548 module/tests/run-suite.sh e2e settle_up_across_anvil_e2e
##
## Held: both payments are plain ETH transfers from Bob's own key, exactly the net amounts, to
## the addresses the settle-up names; each recipient confirms its own from its own read; the
## settle-up is final, and so are all three splits on every member — the Bitcoin hotel by
## Carol's word, with no Bitcoin transaction; the balances move exactly.
import std/[os, strutils, json, httpclient, sequtils, tables]
import stint
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/intent_events
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/parts
import ../src/coordination/parts_evm
import ../src/coordination/settle_up
import ../src/wallet/[types, adapter, evm_adapter, evm_rpc]
import ../src/bitcoin/script
import ./probes/live_room

const Chain = "eip155:31337"
const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const EvmPolicy = "evm-split@" & Chain
const BtcPolicy = "btc-split@" & Regtest
const TokenBin = staticRead("fixtures/MusterTestToken.bin").strip()
let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:8545")

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc addrOf(ks: Keystore): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in ks.address(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == EvmPolicy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol])
  elif policy == BtcPolicy: newSplitDriver(BtcSplitFamily, Regtest, @[alice, bob, carol])
  else: newUnsupportedDriver(policy)

proc rpc(meth: string, params: JsonNode): JsonNode =
  ## A bare JSON-RPC call, for the fixture only (deploying the test token, reading balances).
  let c = newHttpClient()
  defer: c.close()
  c.headers = newHttpHeaders({"Content-Type": "application/json"})
  let r = parseJson(c.postContent(url, $(%*{"jsonrpc": "2.0", "id": 1, "method": meth, "params": params})))
  if r.hasKey("error"): raise newException(IOError, meth & ": " & $r["error"])
  r["result"]

proc receipt(tx: string): JsonNode =
  for _ in 0 ..< 50:
    let r = rpc("eth_getTransactionReceipt", %*[tx])
    if r.kind == JObject: return r
    sleep(100)
  raise newException(IOError, "no receipt for " & tx)

proc ethBalance(who: string): UInt256 = UInt256.fromHex(rpc("eth_getBalance", %*[who, "latest"]).getStr())

proc seamFor(ks: Keystore): EvmPartSeam =
  let a = newEvmAdapter("evm:31337", url, fromUnlocked = false)
  newEvmPartSeam(Chain, url, a, ks, Account(chain: "evm:31337", form: afPublic, id: addrOf(ks)))

try: discard rpcGasPrice(url)
except WalletError as e: quit("no EVM node at " & url & " (" & e.msg & ") — start anvil first", 2)

let payA = addrOf(aliceKs)
let payB = addrOf(bobKs)
let carolEvm = addrOf(room3CarolKs)
let carolBtc = p2wpkhAddress("bcrt", room3CarolKs.btcPubKey())
let token = receipt(rpc("eth_sendTransaction", %*[{"from": payA, "data": "0x" & TokenBin, "gas": "0x200000"}]).getStr()
                   )["contractAddress"].getStr().toLowerAscii()
let mtd = "erc20:" & token
echo "0. deployed ", mtd, " (6 decimals) OK"

var r = newRoom3("/muster/1/settle-up-across-anvil/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
var seqNo = 0'u64
proc propose(s: CoordinationSession, ks: Keystore, policy, effect, account: string,
             reads: seq[tuple[field, source: string]] = @[]): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, policy, effect, int64(Now), seqNo, account = account, ttlSec = Ttl, reads = reads)

let dinner = r.alice.propose(aliceKs, EvmPolicy, splitEffectJson(Chain, "ETH", "900000000000000000", alice, payA,
                              evenShares("900000000000000000", alice, @[bob, carol]), "Dinner"), Chain & ":" & payA)
let taxi = r.bob.propose(bobKs, EvmPolicy, splitEffectJson(Chain, mtd, "600000", bob, payB,
                          evenShares("600000", bob, @[alice, carol]), "Taxi"), Chain & ":" & payB)
let hotel = r.carol.propose(room3CarolKs, BtcPolicy, splitEffectJson(Regtest, "BTC", "6000000", carol, carolBtc,
                             evenShares("6000000", carol, @[alice, bob]), "Hotel"), Regtest & ":" & carolBtc)
doAssert @[dinner, taxi, hotel].allIt(it.startsWith("0x")), $(@[dinner, taxi, hotel])
discard agree(r.bob, bobKs, dinner)
doAssert agree(r.carol, room3CarolKs, dinner) == "executable"
discard agree(r.alice, aliceKs, taxi)
doAssert agree(r.carol, room3CarolKs, taxi) == "executable"
discard agree(r.alice, aliceKs, hotel)
doAssert agree(r.bob, bobKs, hotel) == "executable"
echo "1. dinner in ETH, a taxi in MTD, a hotel in BTC on regtest: all agreed OK"

# ── 2. settled up in ETH at Alice's rates; Carol paid where she said ─────────────────
r.carol.publishAuthored(room3CarolKs, newMessageEvent(carol, int64(Now),
  $(%*{"kind": "address-share", "asset": "ETH", "address": carolEvm, "form": 1}), 1)[1])
sync()
let rates = @[SettleRate(chain: Chain, asset: mtd, rate: "500000000000000000", per: "1000000",
                         source: "Alice's MTD/ETH", at: $Now),
              SettleRate(chain: Regtest, asset: "BTC", rate: "20000000000000000000", per: "100000000",
                         source: "Alice's BTC/ETH", at: $Now)]
let composed = settleUpAcross(r.alice.roomEvents(), splitFor, Chain, "ETH", rates, "Lisbon", Now)
doAssert composed.why == "", composed.why
doAssert composed.covers.len == 6
var net = initTable[string, (string, string)]()
for t in parseJson(composed.effectJson)["transfers"]:
  doAssert t["from"].getStr() == bob, "only Bob owes, net: " & $t
  net[t["to"].getStr()] = (t["payTo"].getStr(), t["amount"].getStr())
doAssert net.getOrDefault(carol) == (carolEvm, "400000000000000000"), "Carol, owed only on Bitcoin, at her shared address: " & $net
doAssert net.getOrDefault(alice) == (payA, "100000000000000000"), $net
doAssert settleAgreeRefusal(effectFromJson(composed.effectJson), carol, @[carolEvm]) == "", "Carol's client holds it"
let su = r.alice.propose(aliceKs, EvmPolicy, composed.effectJson, Chain, @[(field: "rates", source: "rates:proposer")])
doAssert su.startsWith("0x"), su
discard agree(r.bob, bobKs, su)
doAssert agree(r.carol, room3CarolKs, su) == "executable"
echo "2. settled up in ETH: Bob pays Carol 0.4 (at the address she shared) and Alice 0.1 OK"

# ── 3. Bob pays both from his own key; each recipient confirms from its own read ─────
let beforeA = ethBalance(payA)
let beforeC = ethBalance(carolEvm)
let seam = seamFor(bobKs)
var sent: seq[PendingPart]
for _ in 0 ..< 2:
  let (o, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, su, seam, Now, inFlight = sent)
  doAssert o == "", o
  let tx = rpc("eth_getTransactionByHash", %*[pp.tx])
  doAssert tx["from"].getStr().toLowerAscii() == payB and tx["to"].getStr().toLowerAscii() == pp.transfer.to and
           UInt256.fromHex(tx["value"].getStr()) == u256(pp.transfer.amount) and tx["input"].getStr() in ["0x", ""],
           "a plain ETH transfer of exactly the net amount, from Bob's own key: " & $tx
  sent.add pp
for pp in sent:
  var st = ""
  for _ in 0 ..< 50:
    st = liveSettlePartComplete(r.bob, bobKs, splitFor, seam, pp)
    if not st.startsWith("unconfirmed"): break
    sleep(100)
  doAssert st in ["submitted", "settling", "final"], st
sync()
var confirmed = 0
for _ in 0 ..< 50:
  confirmed += liveConfirmParts(r.alice, aliceKs, splitFor, seamFor(aliceKs)).len
  confirmed += liveConfirmParts(r.carol, room3CarolKs, splitFor, seamFor(room3CarolKs)).len
  if confirmed == 2: break
  sleep(100)
doAssert confirmed == 2, "each recipient confirms its own: " & $confirmed
doAssert ethBalance(payA) - beforeA == u256("100000000000000000") and
         ethBalance(carolEvm) - beforeC == u256("400000000000000000"), "Alice +0.1 and Carol +0.4 ETH exactly"
echo "3. Bob's two ETH payments landed; Alice and Carol confirmed from their own reads; balances exact OK"

# ── 4. final: every split, the Bitcoin hotel by Carol's word ──────────────────────────
sync()
doAssert intentState(r.bob.roomEvents(), splitFor, su) == "final"
doAssert settleCovered(r.alice, aliceKs, splitFor, seamFor(aliceKs)).len == 2, "the dinner's two shares"
doAssert settleCovered(r.bob, bobKs, splitFor, seamFor(bobKs)).len == 2, "the taxi's two shares"
doAssert settleCovered(r.carol, room3CarolKs, splitFor, seamFor(room3CarolKs)).len == 2, "the hotel's two shares"
sync()
for s in [r.alice, r.bob, r.carol]:
  for id in [dinner, taxi, hotel]:
    doAssert intentState(s.roomEvents(), splitFor, id) == "final", "every split final on every member"
echo "4. the settle-up final; the ETH dinner, the MTD taxi and the BTC hotel final on all three OK"
echo "settle_up_across_anvil_e2e: all OK"
