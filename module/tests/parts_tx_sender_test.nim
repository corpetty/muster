## exo-d4d.5 (R4) — a split share paid through tx_sender_module, read back through
## eth_rpc_module: the EVM part seam when the member's endpoint is the platform's.
##
## With a fake tx_sender_module and a fake eth_rpc_module behind the platform hooks:
##   * a share is prepared, checked leg for leg against the agreed transfer, then sent; the
##     part's tx is a `txs:<requestId>` marker and the signer handle is in the book;
##   * prepare legs that differ from the agreed payment refuse it, and nothing is sent;
##   * "landed" polls send_status (the poll IS the broadcast): waiting on the person, then a
##     hash, then that hash's receipt read through eth_rpc_module; the report's reference is
##     the hash, never the marker;
##   * a rejected send, or one the sender no longer holds, can never land (partGone);
##   * a token share is transfer(payTo, share) on the token;
##   * the seam still refuses an endpoint serving another chain.

import std/[json, strutils, tables]
import ../src/wallet/[chain_endpoint, tx_sender, types, evm_adapter]
import ../src/crypto/keystore
import ../src/intents/materialization
import ../src/coordination/[parts, parts_evm]

const
  Ep = "logos:eth_rpc_module/11155111"
  Alice = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  Devon = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
  Token = "0x5fbdb2315678afecb367f032d93f642f64180aa3"
  Hash = "0xabababababababababababababababababababababababababababababababab"

# ── fakes ──────────────────────────────────────────────────────────────────────
var rpcAnswers: Table[string, JsonNode]
var senderCalls: seq[tuple[meth: string, args: JsonNode]]
var prepareReply, sendReply, statusReply: JsonNode

proc fakeRpc(chainId: int, meth: string, params: JsonNode, budgetMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: rpcAnswers.getOrDefault(meth, nil)

proc fakeSender(meth: string, args: JsonNode, timeoutMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    senderCalls.add (meth, args)
    case meth
    of "prepare": prepareReply
    of "send": sendReply
    of "send_status": statusReply
    else: nil

proc rpcOk(meth: string, r: JsonNode) =
  rpcAnswers[meth] = %*{"ok": true, "result": r, "route": "proxied"}

proc reset() =
  rpcAnswers.clear(); senderCalls.setLen(0)
  setPlatformRpc(fakeRpc); setTxSender(fakeSender)
  rpcOk("eth_chainId", %"0xaa36a7")
  prepareReply = nil; sendReply = nil; statusReply = nil

proc seam(): EvmPartSeam =
  var sk, seed: array[32, byte]
  sk[31] = 1; seed[31] = 2
  newEvmPartSeam("eip155:11155111", Ep, newEvmAdapter("evm:11155111", Ep, fromUnlocked = false),
                 newInMemoryKeystore(sk, seed), Account(chain: "evm:11155111", form: afPublic, id: Alice))

proc tr(asset, amount: string): PartTransfer =
  PartTransfer(ok: true, chain: "eip155:11155111", asset: asset, to: Devon, amount: amount)

# ── 1. prepare, check, send ────────────────────────────────────────────────────
block:
  reset()
  let s = seam()
  s.notePayment("intent-a", "p1", "dinner")
  prepareReply = %*{"ok": true, "legs": [{"to": Devon, "value": "0x11c37937e08000", "gasLimit": 21000}]}
  sendReply = %*{"ok": true, "pending": true, "requestId": "snd_1", "handle": "ksh_1"}
  let r = s.sendPart(tr("ETH", "5000000000000000"))
  doAssert r.ok, r.detail
  doAssert r.tx == "txs:snd_1"
  doAssert senderCalls.len == 2 and senderCalls[0].meth == "prepare" and senderCalls[1].meth == "send"
  let req = parseJson(senderCalls[1].args[0].getStr())
  doAssert req["chainId"].getInt() == 11155111 and req["from"].getStr() == Alice
  doAssert req["calls"][0]["meta"]["muster"]["intent"].getStr() == "intent-a"
  doAssert req["calls"][0]["meta"]["muster"]["part"].getStr() == "p1"
  doAssert "dinner" in req["purpose"].getStr()
  doAssert sendBook.handleOf("snd_1") == "ksh_1"
  doAssert s.lastSpends().len == 0, "the sender owns the nonce"

# ── 2. legs that are not the agreed payment: nothing sent ──────────────────────
block:
  reset()
  let s = seam()
  prepareReply = %*{"ok": true, "legs": [{"to": Alice, "value": "0x11c37937e08000"}]}
  let r = s.sendPart(tr("ETH", "5000000000000000"))
  doAssert not r.ok and "to:" in r.detail, r.detail
  doAssert senderCalls.len == 1, "send is never called"
  prepareReply = %*{"ok": false, "error": "insufficient funds for value + fee ceiling"}
  let r2 = s.sendPart(tr("ETH", "5000000000000000"))
  doAssert not r2.ok and "insufficient" in r2.detail
  # no tx_sender_module on this host
  setTxSender(nil)
  let r3 = s.sendPart(tr("ETH", "5000000000000000"))
  doAssert not r3.ok and "tx_sender_module" in r3.detail, r3.detail

# ── 3. landed: the person, the broadcast, the receipt ──────────────────────────
block:
  reset()
  let s = seam()
  prepareReply = %*{"ok": true, "legs": [{"to": Devon, "value": "0x7"}]}
  sendReply = %*{"ok": true, "pending": true, "requestId": "snd_3", "handle": "ksh_3"}
  let t = tr("ETH", "7")
  let sent = s.sendPart(t)
  doAssert sent.ok
  statusReply = %*{"ok": true, "status": "awaitingApproval", "final": false}
  var l = s.partLanded(t, sent.tx)
  doAssert not l.ok and "Signer" in l.detail, l.detail
  doAssert senderCalls[^1].meth == "send_status" and senderCalls[^1].args[0].getStr() == "snd_3"
  statusReply = %*{"ok": true, "status": "broadcast", "final": true, "hashes": [Hash], "hash": Hash}
  rpcOk("eth_getTransactionReceipt", newJNull())
  l = s.partLanded(t, sent.tx)
  doAssert not l.ok and "not in a block" in l.detail, l.detail
  rpcOk("eth_getTransactionReceipt", %*{"status": "0x1", "logs": []})
  l = s.partLanded(t, sent.tx)
  doAssert l.ok, l.detail
  doAssert s.landedRef(t, sent.tx) == Hash, "the report names the chain's hash, never the marker"
  rpcOk("eth_getTransactionReceipt", %*{"status": "0x0", "logs": []})
  l = s.partLanded(t, sent.tx)
  doAssert not l.ok and "failed" in l.detail
  doAssert not s.partGone(t, PendingPart(tx: sent.tx, transfer: t)).gone, "a broadcast payment is not gone"

# ── 4. rejected, or lost: it can never land ────────────────────────────────────
block:
  reset()
  let s = seam()
  prepareReply = %*{"ok": true, "legs": [{"to": Devon, "value": "0x7"}]}
  sendReply = %*{"ok": true, "pending": true, "requestId": "snd_4", "handle": "ksh_4"}
  let t = tr("ETH", "7")
  let sent = s.sendPart(t)
  statusReply = %*{"ok": true, "status": "rejected", "final": true}
  let l = s.partLanded(t, sent.tx)
  doAssert not l.ok and "rejected" in l.detail
  doAssert s.partGone(t, PendingPart(tx: sent.tx, transfer: t)).gone
  statusReply = %*{"ok": false, "error": "no send snd_9", "final": true}
  doAssert s.partGone(t, PendingPart(tx: "txs:snd_9", transfer: t)).gone, "a send the sender lost (a restart)"
  statusReply = %*{"ok": false, "error": "budget spent", "final": false}
  doAssert not s.partGone(t, PendingPart(tx: "txs:snd_10", transfer: t)).gone, "a transient refusal is not gone"
  doAssert s.payDeadlineS() >= 1800.0, "a person may take a while in the signer"

# ── 5. a token share ───────────────────────────────────────────────────────────
block:
  reset()
  let s = seam()
  let t = tr("erc20:" & Token, "900000")
  let c = callFor(t)
  prepareReply = %*{"ok": true, "legs": [{"to": Token, "value": "0x0", "data": c.data}]}
  sendReply = %*{"ok": true, "pending": true, "requestId": "snd_5", "handle": "ksh_5"}
  doAssert s.sendPart(t).ok
  let req = parseJson(senderCalls[0].args[0].getStr())
  doAssert req["calls"][0]["to"].getStr() == Token and req["calls"][0]["data"].getStr() == c.data

# ── 6. an endpoint serving another chain ───────────────────────────────────────
block:
  reset()
  rpcOk("eth_chainId", %"0x1")
  let s = seam()
  let r = s.sendPart(tr("ETH", "7"))
  doAssert not r.ok and "eip155:1" in r.detail, r.detail
  doAssert senderCalls.len == 0

echo "parts_tx_sender_test: ok"
