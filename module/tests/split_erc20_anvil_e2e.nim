## A split paid in an ERC-20 token, end to end on a live EVM chain (exo-5ab;
## docs/design/split-the-bill.md): the same three members as split_anvil_e2e, but the bill is
## in a token (tests/fixtures/MusterTestToken.sol, 6 decimals, deployed here). Each debtor's
## OWN key signs a transfer(payTo, share) call on the token; the creditor's client confirms
## from its own read of the receipt's Transfer log.
##
##   anvil --port 8547 &   # any fresh anvil (chain id 31337, the default funded accounts)
##   TEST_ARGS=http://127.0.0.1:8547 module/tests/run-suite.sh e2e split_erc20_anvil_e2e
##
## Held: the payment each debtor's wallet signs is a call on the split's token moving exactly
## the agreed share to payTo; the creditor refuses the right token paid to someone else and
## another token paid to payTo; the creditor's token balance rises by exactly the shares; the
## split is final on all three members.
import std/[os, strutils, json, httpclient]
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

# the fixture: the split's token, and a second token the decoy pays in
let payTo = addrOf(aliceKs)
let token = deployToken(payTo)
let otherToken = deployToken(payTo)
for ks in [bobKs, room3CarolKs]:
  mint(token, payTo, addrOf(ks), 1_000_000)
  mint(otherToken, payTo, addrOf(ks), 1_000_000)
let asset = "erc20:" & token
echo "0. deployed ", asset, " (and a second token); Bob and Carol hold 1 MTD each OK"

var r = newRoom3("/muster/1/split-erc20-anvil/proto")
const Share = "300000"                       # 0.3 MTD at 6 decimals
let effect = splitEffectJson(Chain, asset, "900000", alice, payTo,
                             evenShares("900000", alice, @[bob, carol]), "Team lunch")
let id = liveProposeIntent(r.alice, aliceKs, splitFor, Policy, effect, int64(Now), 1,
                           account = Chain & ":" & payTo, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
doAssert liveContribute(r.bob, bobKs, splitFor, id, "", "", bindCtx(), Now) == "collecting"
doAssert liveContribute(r.carol, room3CarolKs, splitFor, id, "", "", bindCtx(), Now) == "executable"
echo "1. Alice proposes 0.9 MTD among three; Bob and Carol agree to 0.3 MTD each OK"

let before = tokenBalance(token, payTo)

proc pay(s: CoordinationSession, ks: Keystore): string =
  let seam = seamFor(ks)
  let (outcome, pp) = liveSettlePartSend(s, ks, splitFor, id, seam, Now)
  doAssert outcome == "", outcome
  let tx = rpc("eth_getTransactionByHash", %*[pp.tx])
  doAssert tx["to"].getStr().toLowerAscii() == token, "the payment is a call on the split's token: " & $tx["to"]
  doAssert tx["input"].getStr().toLowerAscii() == "0xa9059cbb" & word(payTo) & word(toHex(parseInt(Share))),
           "exactly transfer(payTo, share): " & tx["input"].getStr()
  doAssert tx["from"].getStr().toLowerAscii() == addrOf(ks), "from the payer's own key"
  for _ in 0 ..< 50:
    let st = liveSettlePartComplete(s, ks, splitFor, seam, pp)
    if not st.startsWith("unconfirmed"): return pp.tx
    sleep(100)
  doAssert false, "the payment never landed"

let bobTx = pay(r.bob, bobKs)
echo "2. Bob's own key signed transfer(payTo, 0.3 MTD) on the split's token: ", bobTx, " OK"

# Carol's decoys: the right token paid to someone else, and another token paid to payTo
let carolSeam = seamFor(room3CarolKs)
let aliceSeam = seamFor(aliceKs)
let elsewhere = carolSeam.sendPart(PartTransfer(ok: true, chain: Chain, asset: asset,
                                                to: "0x1111111111111111111111111111111111111111", amount: Share))
let wrongToken = carolSeam.sendPart(PartTransfer(ok: true, chain: Chain, asset: "erc20:" & otherToken,
                                                 to: payTo, amount: Share))
doAssert elsewhere.ok and wrongToken.ok, elsewhere.detail & " / " & wrongToken.detail
discard receipt(elsewhere.tx)
discard receipt(wrongToken.tx)
let why1 = liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, elsewhere.tx)
doAssert why1.startsWith("unconfirmed") and "0x1111" in why1, why1
let why2 = liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, wrongToken.tx)
doAssert why2.startsWith("unconfirmed") and "another token" in why2, why2
echo "3. the right token paid elsewhere, and another token paid to Alice: both refused OK"

let carolTx = pay(r.carol, room3CarolKs)
echo "4. Carol pays her share: ", carolTx, " OK"

var confirmed: seq[string]
for _ in 0 ..< 50:
  confirmed.add liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam)
  if confirmed.len == 2: break
  sleep(100)
doAssert confirmed.len == 2, "the creditor's own reads confirm both shares: " & $confirmed
for s in [r.alice, r.bob, r.carol]:
  s.poll()
for s in [r.alice, r.bob, r.carol]:
  doAssert intentState(s.roomEvents(), splitFor, id) == "final", "final on every member"
let after = tokenBalance(token, payTo)
doAssert after - before == u256(Share) * 2.u256, "Alice received exactly the two shares: " & $(after - before)
echo "5. Alice's client confirms both from the Transfer logs; +0.6 MTD; final on all three members OK"

echo "split_erc20_anvil_e2e: all OK"
