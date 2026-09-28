## A split, end to end on a live EVM chain (exo-a90.8; docs/design/split-the-bill.md): three
## members in-process, their room keys agreeing in the room, their OWN secp keys (anvil
## accounts 0/1/2, held in their keystores) signing their own EIP-155 payments, and the
## creditor's client confirming each payment from its own RPC read. No Safe, no contract:
## anvil is only the chain.
##
##   anvil --port 8547 &   # any fresh anvil (chain id 31337, the default funded accounts)
##   TEST_ARGS=http://127.0.0.1:8547 module/tests/run-suite.sh e2e split_anvil_e2e
##
## Held: the payment each debtor's wallet signs is exactly the agreed share to the agreed
## address; the creditor's balance rises by exactly the shares; a reported transaction
## that pays someone else is never confirmed; the split is final on all three members.

import std/[os, strutils]
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
import ../src/wallet/[types, adapter, evm_adapter, evm_rpc]
import ./probes/live_room

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:8547")
const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain

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

# each member's own wallet: client-side EIP-155 signing through their keystore
proc seamFor(ks: Keystore): EvmPartSeam =
  let a = newEvmAdapter("evm:31337", url, fromUnlocked = false)
  newEvmPartSeam(Chain, url, a, ks, Account(chain: "evm:31337", form: afPublic, id: addrOf(ks)))

try: discard rpcGasPrice(url)
except WalletError as e: quit("no EVM node at " & url & " (" & e.msg & ") — start anvil first", 2)

var r = newRoom3("/muster/1/split-anvil/proto")
let payTo = addrOf(aliceKs)
const Share = "300000000000000000"          # 0.3 ETH
let effect = splitEffectJson(Chain, "ETH", "900000000000000000", alice, payTo,
                             evenShares("900000000000000000", alice, @[bob, carol]), "Dinner at Tasca")
let id = liveProposeIntent(r.alice, aliceKs, splitFor, Policy, effect, int64(Now), 1,
                           account = Chain & ":" & payTo, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
doAssert liveContribute(r.bob, bobKs, splitFor, id, "", "", bindCtx(), Now) == "collecting"
doAssert liveContribute(r.carol, room3CarolKs, splitFor, id, "", "", bindCtx(), Now) == "executable"
echo "1. Alice proposes 0.9 ETH among three; Bob and Carol agree to 0.3 ETH each OK"

let before = u256(rpcBalance(url, payTo, "latest"))

proc pay(s: CoordinationSession, ks: Keystore): string =
  let seam = seamFor(ks)
  let (outcome, pp) = liveSettlePartSend(s, ks, splitFor, id, seam, Now)
  doAssert outcome == "", outcome
  let got = rpcTransferOf(url, pp.tx)
  doAssert got.found and got.fromHex.toLowerAscii() == addrOf(ks) and got.toHex.toLowerAscii() == payTo and
           got.valueDec == Share, "the wallet signed exactly the agreed share, from the payer, to payTo: " & $got
  for _ in 0 ..< 50:
    let st = liveSettlePartComplete(s, ks, splitFor, seam, pp)
    if not st.startsWith("unconfirmed"): return pp.tx
    sleep(100)
  doAssert false, "the payment never landed"

let bobTx = pay(r.bob, bobKs)
echo "2. Bob's own key signed an EIP-155 transfer of exactly his share to Alice: ", bobTx, " OK"

# Carol first reports a transaction that pays someone else — the creditor's read refuses it
let decoy = seamFor(room3CarolKs).sendPart(PartTransfer(ok: true, chain: Chain, asset: "ETH",
                                                        to: "0x1111111111111111111111111111111111111111", amount: Share))
doAssert decoy.ok, decoy.detail
sleep(200)
let aliceSeam = seamFor(aliceKs)
let why = liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, decoy.tx)
doAssert why.startsWith("unconfirmed") and "pays 0x1111" in why, why
echo "3. a transaction that pays someone else is never confirmed: ", why, " OK"

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
let after = u256(rpcBalance(url, payTo, "latest"))
doAssert after - before == u256(Share) * 2.u256, "Alice received exactly the two shares: " & $(after - before)
echo "5. Alice's client confirms both from her RPC; +0.6 ETH; final on all three members OK"

echo "split_anvil_e2e: all OK"
