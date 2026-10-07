## exo-d4d.5 (R4) — a transaction the EVM adapter submits on a platform endpoint goes through
## tx_sender_module: a Safe's execTransaction (the settlement seam) and, later, a wallet send.
##
## With a fake tx_sender_module and eth_rpc_module behind the platform hooks:
##   * submit prepares the payload's one call, checks the legs are exactly it, and sends;
##     the TxRef is a `txs:<requestId>` marker, never a hash the sender has not given;
##   * finality: pending while the person has not approved (saying so), then the hash's
##     receipt; failed when the person rejected it; resolvedRef names the hash;
##   * the payload's purpose reaches the signer; an anvil-unlocked adapter never takes this
##     path (a local test chain signs for itself).

import std/[json, strutils, tables]
import ../src/wallet/[chain_endpoint, tx_sender, types, adapter, evm_adapter]
import ../src/crypto/keystore

const
  Ep = "logos:eth_rpc_module/11155111"
  Owner = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  Safe = "0xeb4520e32862d2adfa2af042f0b5ea2041dee841"
  Hash = "0xcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"

var rpcAnswers: Table[string, JsonNode]
var calls: seq[tuple[meth: string, args: JsonNode]]
var prepareReply, sendReply, statusReply: JsonNode

proc fakeRpc(chainId: int, meth: string, params: JsonNode, budgetMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: rpcAnswers.getOrDefault(meth, nil)
proc fakeSender(meth: string, args: JsonNode, timeoutMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    calls.add (meth, args)
    case meth
    of "prepare": prepareReply
    of "send": sendReply
    of "send_status": statusReply
    else: nil

proc reset() =
  rpcAnswers.clear(); calls.setLen(0)
  setPlatformRpc(fakeRpc); setTxSender(fakeSender)

proc ks(): Keystore =
  var sk, seed: array[32, byte]
  sk[31] = 1; seed[31] = 2
  newInMemoryKeystore(sk, seed)

let data = "0x6a761202" & repeat("00", 64)
let prepared = PreparedTx(chain: "evm:11155111",
  frm: Account(chain: "evm:11155111", form: afPublic, id: Owner), to: Safe,
  payload: $(%*{"to": Safe, "data": data, "gas": 400_000,
                "purpose": "Settle 'pay the venue' (2 of 3 owners agreed in a Muster room)"}))

# ── 1. submit: prepare, check, send ────────────────────────────────────────────
block:
  reset()
  let a = newEvmAdapter("evm:11155111", Ep, fromUnlocked = false)
  prepareReply = %*{"ok": true, "legs": [{"to": Safe, "value": "0x0", "data": data, "gasLimit": 120000}]}
  sendReply = %*{"ok": true, "pending": true, "requestId": "snd_s1", "handle": "ksh_s1"}
  let r = a.submit(prepared, ks())
  doAssert r.id == "txs:snd_s1", r.id
  doAssert calls.len == 2 and calls[0].meth == "prepare" and calls[1].meth == "send"
  let req = parseJson(calls[1].args[0].getStr())
  doAssert req["from"].getStr() == Owner and req["chainId"].getInt() == 11155111
  doAssert req["calls"][0]["to"].getStr() == Safe and req["calls"][0]["data"].getStr() == data
  doAssert "pay the venue" in req["purpose"].getStr()
  doAssert sendBook.handleOf("snd_s1") == "ksh_s1"

# ── 2. legs that are not the payload: refused, nothing sent ───────────────────
block:
  reset()
  let a = newEvmAdapter("evm:11155111", Ep, fromUnlocked = false)
  prepareReply = %*{"ok": true, "legs": [{"to": Safe, "value": "0x0", "data": "0x6a761202"}]}
  var raised = ""
  try: discard a.submit(prepared, ks())
  except WalletError as e: raised = e.msg
  doAssert "data:" in raised, raised
  doAssert calls.len == 1

# ── 3. finality ────────────────────────────────────────────────────────────────
block:
  reset()
  let a = newEvmAdapter("evm:11155111", Ep, fromUnlocked = false)
  prepareReply = %*{"ok": true, "legs": [{"to": Safe, "value": "0x0", "data": data}]}
  sendReply = %*{"ok": true, "pending": true, "requestId": "snd_s3", "handle": "ksh_s3"}
  let r = a.submit(prepared, ks())
  statusReply = %*{"ok": true, "status": "awaitingApproval", "final": false}
  var f = a.finality(r)
  doAssert f.status == fsPending and "Signer" in f.detail, f.detail
  doAssert resolvedRef(r) == "", "no hash before the broadcast"
  statusReply = %*{"ok": true, "status": "broadcast", "final": true, "hashes": [Hash], "hash": Hash}
  rpcAnswers["eth_getTransactionReceipt"] = %*{"ok": true, "result": nil, "route": "proxied"}
  f = a.finality(r)
  doAssert f.status == fsPending
  doAssert resolvedRef(r) == Hash
  rpcAnswers["eth_getTransactionReceipt"] = %*{"ok": true, "result": {"status": "0x1", "logs": []}, "route": "proxied"}
  doAssert a.finality(r).status == fsFinal
  reset()
  statusReply = %*{"ok": true, "status": "rejected", "final": true}
  sendBook.add("snd_s4", "ksh_s4", "", "", "")
  f = a.finality(TxRef(chain: "evm:11155111", id: "txs:snd_s4"))
  doAssert f.status == fsFailed and "rejected" in f.detail

# ── 4. a local test chain that signs for itself never takes this path ──────────
block:
  reset()
  let a = newEvmAdapter("evm:31337", "http://127.0.0.1:1", fromUnlocked = true)
  try: discard a.submit(prepared, ks())
  except CatchableError: discard
  doAssert calls.len == 0

# ── 5. the wallet's account on the platform is the person's keystore account ──
block:
  reset()
  let a = newEvmAdapter("evm:11155111", Ep, fromUnlocked = false, owner = Owner)
  let accts = a.accounts(ks())
  doAssert accts.len == 1 and accts[0].id == Owner, "not muster's own key's address"
  rpcAnswers["eth_getBalance"] = %*{"ok": true, "result": "0x2386f26fc10000", "route": "verified"}
  doAssert a.balance(accts[0], a.describe().nativeAsset).raw == "10000000000000000"
  # without an owner, the adapter names the keystore's own address, as before
  doAssert newEvmAdapter("evm:31337", "http://127.0.0.1:1").accounts(ks())[0].id != Owner

echo "evm_adapter_platform_test: ok"
