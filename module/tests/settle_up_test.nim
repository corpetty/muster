## Settle up: net several splits into fewer payments (exo-3c6; docs/design/split-the-bill.md
## §4.11). Held here, without a room:
##   * the net transfers conserve every member's balance across the parts they cover —
##     what each is owed minus what each owes — and are no more than the parts they replace;
##   * a settle-up effect has one spelling, and the driver refuses one whose transfers do
##     not conserve the covered balances, pay a recipient anywhere but the address one of
##     their covered splits agreed, or settle the private split (whose shares are told
##     apart by amount — netting would erase that);
##   * everyone the covered parts name agrees (each debtor and each creditor), and each net
##     transfer is a part: paid by its payer, confirmed by its recipient — a payer who owes
##     two people has two parts;
##   * the covers and the transfers are the signed bytes.
## Needs libsodium (Ed25519).

import std/[json, strutils, sequtils, algorithm, tables]
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/split
import ../src/intents/materialization
import ../src/crypto/curve25519
import ../src/coordination/intent_events
import ../src/coordination/settle_up

const Chain = "eip155:31337"
proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc filled(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc idOf(k: EncKeys): string = hexOf(k.identity().toBytes())
let alice = encFromSeed(filled(71))
let bob = encFromSeed(filled(72))
let carol = encFromSeed(filled(73))
let (a, b, c) = (idOf(alice), idOf(bob), idOf(carol))
const PayA = "0xaaaa000000000000000000000000000000000001"
const PayB = "0xbbbb000000000000000000000000000000000002"
const S1 = "0x1111111111111111"
const S2 = "0x2222222222222222"

# dinner (S1): Alice fronted, Bob and Carol owe her 300 each; taxi (S2): Bob fronted, Alice
# and Carol owe him 200 each. Net: Alice +400, Bob +100, Carol −500.
let covers = @[
  Cover(intent: S1, debtor: b, creditor: a, amount: "300", payTo: PayA),
  Cover(intent: S1, debtor: c, creditor: a, amount: "300", payTo: PayA),
  Cover(intent: S2, debtor: a, creditor: b, amount: "200", payTo: PayB),
  Cover(intent: S2, debtor: c, creditor: b, amount: "200", payTo: PayB)]

proc netOf(ts: seq[NetTransfer]): Table[string, int] =
  for t in ts:
    result[t.frm] = result.getOrDefault(t.frm) - parseInt(t.amount)
    result[t.to] = result.getOrDefault(t.to) + parseInt(t.amount)

# ── 1. the net transfers conserve every balance, in fewer payments ────────────────
block:
  let ts = netTransfers(covers)
  let n = netOf(ts)
  doAssert n.getOrDefault(a) == 400 and n.getOrDefault(b) == 100 and n.getOrDefault(c) == -500, $n
  doAssert ts.len == 2, "four payments become two: " & $ts
  doAssert ts.allIt(it.frm == c), "only Carol owes, net"
  for t in ts:
    doAssert t.payTo == (if t.to == a: PayA else: PayB), "a recipient is paid where their own split said"
  doAssert netTransfers(@[covers[0], covers[2]]).mapIt((it.frm, it.to, it.amount)) == @[(b, a, "100")],
           "Bob owes Alice 300, she owes him 200: Bob pays 100"
  doAssert netTransfers(@[covers[0], Cover(intent: S2, debtor: a, creditor: b, amount: "300", payTo: PayB)]).len == 0,
           "debts that cancel exactly need no payment"
  echo "1. netting conserves every member's balance, in fewer payments OK"

# ── 2. the driver: one spelling, conservation, the recipient's own address ────────
let drv = newSplitDriver(EvmSplitFamily, Chain, @[a, b, c])
let good = settleUpEffectJson(Chain, "ETH", covers, netTransfers(covers), "Lisbon")
block:
  let e = effectFromJson(good)
  doAssert drv.signRefusal(e) == "", drv.signRefusal(e)
  # a transfer that does not conserve the balances (Carol pays Alice one unit less)
  var ts = netTransfers(covers)
  for t in ts.mitems:
    if t.to == a: t.amount = $(parseInt(t.amount) - 1)
  doAssert "balance" in drv.signRefusal(effectFromJson(settleUpEffectJson(Chain, "ETH", covers, ts, "x"))),
           "a netting that does not conserve is refused"
  # a recipient paid somewhere their split never agreed
  var elsewhere = netTransfers(covers)
  elsewhere[0].payTo = "0xeeee000000000000000000000000000000000003"
  doAssert "address" in drv.signRefusal(effectFromJson(settleUpEffectJson(Chain, "ETH", covers, elsewhere, "x")))
  let lez = newSplitDriver(LezSplitFamily, "lez:testnet", @[a, b, c])
  doAssert lez.signRefusal(effectFromJson(settleUpEffectJson("lez:testnet", "LEZ", covers, netTransfers(covers), "x"))).len > 0,
           "the private split is never netted"
  echo "2. a settle-up must conserve, pay each recipient at their own agreed address, never net the private split OK"

# ── 3. who agrees, and the parts: one per net transfer ────────────────────────────
block:
  let e = effectFromJson(good)
  doAssert describeFor(drv, e).threshold == 3, "everyone the covered parts name"
  doAssert drv.mayContribute(e, @["ed:" & hexOf(alice.identity().ed)]) == elYes
  doAssert drv.mayContribute(e, @["ed:" & hexOf(encFromSeed(filled(99)).identity().ed)]) == elNo
  let parts = drv.settlementParts(e)
  doAssert parts.len == 2, "a part per net transfer: " & $parts
  for p in parts:
    doAssert drv.partAuthor(e, p, "settled") == c, "Carol pays both"
    let t = drv.partTransfer(e, p)
    doAssert t.ok and t.chain == Chain and t.asset == "ETH"
    doAssert drv.partAuthor(e, p, "confirmed") == (if t.to == PayA: a else: b), "each recipient confirms their own"
  doAssert drv.agreesByProposing(e, a), "a party proposing a settle-up agrees to it"
  let m = decode(canonicalize(drv, e).bytes)
  doAssert m.kind == ckArray and m.arr[0].t == SettleUpDomain, "its own domain: never mistaken for a split"
  let other = settleUpEffectJson(Chain, "ETH", covers, netTransfers(covers), "Porto")
  doAssert canonicalize(drv, effectFromJson(other)).bytes != canonicalize(drv, e).bytes
  echo "3. every named party agrees; each net transfer is a part, paid by its payer, confirmed by its recipient OK"

echo "settle_up_test: all OK"
