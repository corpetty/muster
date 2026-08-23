## The wallet seam proven against a genuinely non-EVM chain: dual public/shielded
## accounts, multi-asset balances, delayed finality (debit now, recipient credited
## on settlement), and the sentinel-failure defense (an unanswerable read raises,
## never reads as zero). Needs libsecp256k1 + libsodium (keystore identity).

import std/strutils
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/wallet/mock_chain
import ../src/crypto/keystore

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

let ks = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let chain = newMockChain(confirmTicks = 2)
let w = newWallet(ks)
w.register(chain)

# 1. Two account forms from one identity; a native + a token asset registered.
let accs = w.accounts()
doAssert accs.len == 2, "public + shielded accounts"
doAssert accs[0].form == afPublic and accs[1].form == afShielded
doAssert w.assets().len == 2, "native MOCK + token MTK"
let pub = accs[0]
let shld = accs[1]
echo "1. dual account model + asset registry OK"

# 2. Multi-asset balances read back and format per-asset.
chain.credit(pub.id, "MOCK", "5000000000")   # 5 MOCK (9 decimals)
chain.credit(pub.id, "MTK", "1230000")        # 1.23 MTK (6 decimals)
doAssert w.balance("mock:shielded", pub, chain.assets()[0]).display() == "5 MOCK"
doAssert w.balance("mock:shielded", pub, chain.assets()[1]).display() == "1.23 MTK"
echo "2. multi-asset balances OK"

# 3. Sentinel-failure defense: reading a never-funded account RAISES — it must not
#    come back as a zero balance.
var sentinelRaised = false
try: discard w.balance("mock:shielded", shld, chain.assets()[0])
except WalletError: sentinelRaised = true
doAssert sentinelRaised, "an unanswerable read raises, never reads as zero"
echo "3. sentinel-failure defense OK"

# 4. Delayed finality + the stale-read trap: send debits the sender NOW, but the
#    recipient balance does not move until settlement completes.
let native = chain.assets()[0]
let ref0 = w.send("mock:shielded", pub, shld.id, amount(native, "2000000000"))  # 2 MOCK
doAssert w.balance("mock:shielded", pub, native).display() == "3 MOCK", "sender debited immediately"
doAssert w.finality(ref0).status == fsPending, "still settling right after send"
var recipientMoved = false
try: recipientMoved = w.balance("mock:shielded", shld, native).raw != "0"
except WalletError: recipientMoved = false
doAssert not recipientMoved, "recipient balance is stale until settlement (the LEZ trap)"
echo "4. delayed finality: debit now, credit later OK"

# 5. After enough ticks the transfer settles and the recipient is credited.
chain.tick(); chain.tick()
doAssert w.finality(ref0).status == fsFinal, "settled after confirmTicks"
doAssert w.balance("mock:shielded", shld, native).display() == "2 MOCK", "recipient now credited"
echo "5. settlement credits the recipient OK"

# 6. Insufficient funds is a raise, never a silent success.
var overspent = false
try: discard w.send("mock:shielded", pub, shld.id, amount(native, "999000000000"))
except WalletError: overspent = true
doAssert overspent, "overspending is refused"
echo "6. insufficient funds refused OK"

# 7. Fee estimation is chain-described (a proof cost here, not gas).
let fee = w.estimateFee("mock:shielded", pub, shld.id, amount(native, "1"))
doAssert fee.fee.asset.symbol == "MOCK" and fee.note.len > 0
echo "7. chain-described fee estimate OK"

echo "wallet_mock_test: all OK"
