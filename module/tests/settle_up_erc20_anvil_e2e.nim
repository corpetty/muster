## Settle up in an ERC-20 token, end to end on a live EVM chain (exo-a90.18;
## docs/design/split-the-bill.md §4.11). Dinner (Bob and Carol owe Alice 0.3 MTD each) and a
## taxi (Alice and Carol owe Bob 0.2 MTD each), both in the test token; settled up, Carol pays
## Alice 0.4 MTD and Bob 0.1 MTD — two transfer calls on the token from her own key, the
## second sent while the first is still pending (automine off).
##
##   anvil --port 8547 &   # any fresh anvil (chain id 31337, the default funded accounts)
##   TEST_ARGS=http://127.0.0.1:8547 module/tests/run-suite.sh e2e settle_up_erc20_anvil_e2e
##
## Held: each net payment is exactly transfer(recipient's payTo, net amount) on the split's
## token, from Carol's own key, the second at the next nonce (both pending at once, neither
## replacing the other); each recipient confirms its own from the receipt's Transfer log; the
## settle-up, then both splits, final on every member; the token balances move exactly. And
## (exo-a90.23) a payment the chain can no longer land is known as such: pending or mined it
## is not gone; dropped from the mempool with its nonce free again, it is.
import std/[os, strutils, json, httpclient, sequtils, algorithm]
import stint
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/crypto/secp256k1
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/parts
import ../src/coordination/parts_evm
import ../src/coordination/settle_up
import ../src/wallet/[types, adapter, evm_adapter, evm_rpc, erc20_logs]
import ./probes/live_room

const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
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
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)

proc rpc(meth: string, params: JsonNode): JsonNode =
  ## A bare JSON-RPC call, for the fixture only (deploying and minting the test token).
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

proc word(hex: string): string = hex.replace("0x", "").toLowerAscii().align(64, '0')

proc deployToken(frm: string): string =
  receipt(rpc("eth_sendTransaction", %*[{"from": frm, "data": "0x" & TokenBin, "gas": "0x200000"}]).getStr())["contractAddress"].getStr().toLowerAscii()

proc mint(token, frm, to: string, amount: int) =
  discard receipt(rpc("eth_sendTransaction", %*[{"from": frm, "to": token, "gas": "0x30000",
    "data": "0x40c10f19" & word(to) & word(toHex(amount))}]).getStr())

proc tokenBalance(token, owner: string): UInt256 =
  let raw = rpc("eth_call", %*[{"to": token, "data": "0x70a08231" & word(owner)}, "latest"]).getStr()
  UInt256.fromHex(raw)

# each member's own wallet: client-side EIP-155 signing through their keystore
proc seamFor(ks: Keystore): EvmPartSeam =
  let a = newEvmAdapter("evm:31337", url, fromUnlocked = false)
  newEvmPartSeam(Chain, url, a, ks, Account(chain: "evm:31337", form: afPublic, id: addrOf(ks)))

try: discard rpcGasPrice(url)
except WalletError as e: quit("no EVM node at " & url & " (" & e.msg & ") — start anvil first", 2)

# the fixture: the token; Carol holds 1 MTD (Alice and Bob only receive here)
let payA = addrOf(aliceKs)
let payB = addrOf(bobKs)
let token = deployToken(payA)
mint(token, payA, addrOf(room3CarolKs), 1_000_000)
discard rpc("anvil_setBalance", %*[addrOf(room3CarolKs), "0x56BC75E2D63100000"])   # gas: 100 ETH
let asset = "erc20:" & token
echo "0. deployed ", asset, "; Carol holds 1 MTD OK"

var r = newRoom3("/muster/1/settle-up-erc20-anvil/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
var seqNo = 0'u64
proc propose(s: CoordinationSession, ks: Keystore, effect, payTo: string): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, Policy, effect, int64(Now), seqNo, account = Chain & ":" & payTo, ttlSec = Ttl)

let dinner = r.alice.propose(aliceKs, splitEffectJson(Chain, asset, "900000", alice, payA,
                              evenShares("900000", alice, @[bob, carol]), "Dinner"), payA)
let taxi = r.bob.propose(bobKs, splitEffectJson(Chain, asset, "600000", bob, payB,
                          evenShares("600000", bob, @[alice, carol]), "Taxi"), payB)
discard agree(r.bob, bobKs, dinner)
doAssert agree(r.carol, room3CarolKs, dinner) == "executable"
discard agree(r.alice, aliceKs, taxi)
doAssert agree(r.carol, room3CarolKs, taxi) == "executable"
sync()
let open = openParts(r.alice.roomEvents(), splitFor, Chain, asset, Now)
doAssert open.len == 4, $open.len
let net = netTransfers(open)
doAssert net.len == 2 and net.allIt(it.frm == carol)
let su = r.alice.propose(aliceKs, settleUpEffectJson(Chain, asset, open, net, "Lisbon"), payA)
doAssert su.startsWith("0x"), su
discard agree(r.bob, bobKs, su)
doAssert agree(r.carol, room3CarolKs, su) == "executable"
echo "1. two splits in the token, settled up: Carol pays Alice 0.4 MTD and Bob 0.1 MTD OK"

let beforeA = tokenBalance(token, payA)
let beforeB = tokenBalance(token, payB)

# ── 2. Carol pays both while the first is still pending ────────────────────────────
discard rpc("evm_setAutomine", %*[false])
let seam = seamFor(room3CarolKs)
let (o1, pp1) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, seam, Now)
doAssert o1 == "", o1
let (o2, pp2) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, seam, Now, inFlight = @[pp1])
doAssert o2 == "", "the second is sent while the first is pending: " & o2
for pp in [pp1, pp2]:
  let tx = rpc("eth_getTransactionByHash", %*[pp.tx])
  doAssert tx.kind == JObject, "pending, not replaced: " & pp.tx
  doAssert tx["to"].getStr().toLowerAscii() == token, "a call on the split's token"
  doAssert tx["input"].getStr().toLowerAscii() == "0xa9059cbb" & word(pp.transfer.to) &
           word(toHex(parseInt(pp.transfer.amount))), "exactly transfer(payTo, net amount): " & tx["input"].getStr()
  doAssert tx["from"].getStr().toLowerAscii() == addrOf(room3CarolKs), "from Carol's own key"
let n1 = rpc("eth_getTransactionByHash", %*[pp1.tx])["nonce"].getStr()
let n2 = rpc("eth_getTransactionByHash", %*[pp2.tx])["nonce"].getStr()
doAssert n1 != n2, "two nonces, neither payment replacing the other: " & n1 & " / " & n2
doAssert @[pp1.transfer.amount, pp2.transfer.amount].sorted() == @["100000", "400000"]
discard rpc("evm_mine", newJArray())
discard rpc("evm_setAutomine", %*[true])
echo "2. Carol's two payments, the second while the first is pending: nonces ", n1, " and ", n2, " OK"

# ── 3. reported; each recipient confirms its own; all final ────────────────────────
for pp in [pp1, pp2]:
  var st = ""
  for _ in 0 ..< 50:
    st = liveSettlePartComplete(r.carol, room3CarolKs, splitFor, seam, pp)
    if not st.startsWith("unconfirmed"): break
    sleep(100)
  doAssert st in ["submitted", "settling", "final"], st
sync()
var confirmed = 0
for _ in 0 ..< 50:
  confirmed += liveConfirmParts(r.alice, aliceKs, splitFor, seamFor(aliceKs)).len
  confirmed += liveConfirmParts(r.bob, bobKs, splitFor, seamFor(bobKs)).len
  if confirmed == 2: break
  sleep(100)
doAssert confirmed == 2, "each recipient confirms its own from the Transfer log: " & $confirmed
sync()
doAssert intentState(r.carol.roomEvents(), splitFor, su) == "final"
discard settleCovered(r.alice, aliceKs, splitFor, seamFor(aliceKs))
discard settleCovered(r.bob, bobKs, splitFor, seamFor(bobKs))
sync()
for s in [r.alice, r.bob, r.carol]:
  doAssert intentState(s.roomEvents(), splitFor, dinner) == "final" and intentState(s.roomEvents(), splitFor, taxi) == "final"
doAssert tokenBalance(token, payA) - beforeA == u256(400_000) and tokenBalance(token, payB) - beforeB == u256(100_000),
         "Alice +0.4 and Bob +0.1 MTD exactly"
echo "3. confirmed from the Transfer logs; the settle-up and both splits final on all three; balances exact OK"

# ── 4. partGone: gone only when the RPC no longer knows it and its nonce is settled ────
block:
  let t = PartTransfer(ok: true, chain: Chain, asset: asset, to: payA, amount: "1000")
  discard rpc("evm_setAutomine", %*[false])
  let sent = seam.sendPart(t)
  doAssert sent.ok, sent.detail
  let p = PendingPart(tx: sent.tx, transfer: t, spends: seam.lastSpends())
  doAssert p.spends.len == 1 and p.spends[0].startsWith("nonce:"), $p.spends
  doAssert not seam.partGone(t, p).gone, "pending: it may still land"
  discard rpc("anvil_dropTransaction", %*[sent.tx])
  let why = seam.partGone(t, p)
  doAssert why.gone, "dropped, its nonce free again: a new payment takes it, so at most one lands — " & why.detail
  let again = seam.sendPart(t)
  doAssert again.ok and seam.lastSpends() == p.spends, "the new payment takes the same nonce: " & $seam.lastSpends()
  discard rpc("evm_mine", newJArray())
  discard rpc("evm_setAutomine", %*[true])
  doAssert not seam.partGone(t, PendingPart(tx: again.tx, transfer: t, spends: seam.lastSpends())).gone,
           "a mined payment is never gone"
  echo "4. partGone: pending or mined it may land; dropped with its nonce free, a new payment takes the nonce OK"

echo "settle_up_erc20_anvil_e2e: all OK"
