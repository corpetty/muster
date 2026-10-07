## exo-d4d.3 (R2) — an EVM chain read goes to the platform's eth_rpc_module when the
## endpoint names it, and reads exactly as it does from a URL.
##
## Under Basecamp the person's chains and endpoints live in eth_rpc_module, device-wide
## (invariant 8: still theirs, now set once). An endpoint is either a URL muster calls
## itself (the runner, anvil) or `logos:eth_rpc_module/<chainId>`, which goes over lp_* to
## eth_rpc_module, whose every reply is the envelope {ok, result, route} or {ok:false, error}.
## Held here, with a fake eth_rpc_module behind the platform hook:
##   * the endpoint parses: a URL is direct, the platform form names a chain, anything else
##     raises;
##   * a platform call carries its method and params unchanged, within the caller's budget;
##   * an `ok:false` envelope, no answer, or no eth_rpc_module raises RpcError — never a
##     value (the wallet's rule: failure is always a raise);
##   * every evm_rpc read decodes the platform's JSON exactly as nim-web3 decodes a URL's:
##     balance, call, gas price, chain id, both nonces, receipt status, transfer-of, receipt
##     logs, the account proof; null stays "pending" / "not known" where null is the chain's
##     answer;
##   * a read reports its route, so a balance can be badged verified only when eth_rpc_module
##     proved it (F-10);
##   * an anvil-unlocked send is refused on the platform: nothing there signs for muster;
##   * the Safe reads (drivers/safe_rpc.nim) take the same path: owners, threshold, the
##     liveness probe.

import std/[json, strutils, tables]
import stint
import ../src/wallet/rpc_budget
import ../src/wallet/chain_endpoint
import ../src/wallet/evm_rpc
import ../src/wallet/types
import ../src/drivers/safe
import ../src/drivers/safe_rpc

const
  Sepolia = 11155111
  Ep = "logos:eth_rpc_module/11155111"
  Alice = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  TxHash = "0x" & repeat("ab", 32)

# ── a fake eth_rpc_module ─────────────────────────────────────────────────────
type Seen = object
  chainId: int
  meth: string
  params: JsonNode
  budgetMs: int

var answers: Table[string, JsonNode]    # method → the envelope to answer with
var seen: seq[Seen]

proc fake(chainId: int, meth: string, params: JsonNode, budgetMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    seen.add Seen(chainId: chainId, meth: meth, params: params, budgetMs: budgetMs)
    answers.getOrDefault(meth, nil)

proc answer(meth: string, result: JsonNode, route = "direct") =
  answers[meth] = %*{"ok": true, "result": result, "route": route}

proc refuse(meth, error: string) =
  answers[meth] = %*{"ok": false, "error": error}

proc reset() =
  answers.clear(); seen.setLen(0)
  setPlatformRpc(fake)

proc raisesRpc(body: proc()): string =
  try: body()
  except RpcError as e: return e.msg
  except WalletError as e: return e.msg
  doAssert false, "expected a raise"

# ── 1. the endpoint ───────────────────────────────────────────────────────────
block:
  doAssert parseEndpoint("http://127.0.0.1:8545").kind == ekDirect
  doAssert parseEndpoint("https://rpc.example/v1?key=x").url == "https://rpc.example/v1?key=x"
  let p = parseEndpoint(Ep)
  doAssert p.kind == ekPlatform and p.chainId == Sepolia
  doAssert platformEndpoint(Sepolia) == Ep
  doAssert Ep.isPlatform and not "http://127.0.0.1:8545".isPlatform
  for bad in ["logos:eth_rpc_module/", "logos:eth_rpc_module/abc", "logos:eth_rpc_module/-1",
              "logos:other_module/1", "ftp://x", ""]:
    var raised = false
    try: discard parseEndpoint(bad)
    except RpcError: raised = true
    doAssert raised, "not an endpoint: " & bad

# ── 2. a platform call: method, params and budget go through unchanged ────────
block:
  reset()
  answer("eth_blockNumber", %"0x10", "proxied")
  let r = chainRpc(Ep, "eth_blockNumber", newJArray(), 1500.milliseconds)
  doAssert r.result.getStr() == "0x10" and r.route == "proxied"
  doAssert seen.len == 1 and seen[0].chainId == Sepolia and seen[0].meth == "eth_blockNumber"
  doAssert seen[0].params == newJArray() and seen[0].budgetMs == 1500

# ── 3. failure is a raise ─────────────────────────────────────────────────────
block:
  reset()
  refuse("eth_getBalance", "no configuration for chain 11155111")
  let m = raisesRpc(proc() = discard rpcBalance(Ep, Alice, "latest"))
  doAssert "no configuration for chain 11155111" in m, m
  doAssert "eth_getBalance" in m, "the message names the call: " & m
  # eth_rpc_module did not answer (not loaded, or past the budget)
  let m2 = raisesRpc(proc() = discard rpcChainId(Ep))
  doAssert "eth_rpc_module" in m2, m2
  # no platform hook at all (the runner, a test)
  setPlatformRpc(nil)
  let m3 = raisesRpc(proc() = discard rpcGasPrice(Ep))
  doAssert "eth_rpc_module" in m3, m3
  # an envelope with no result where a value is needed
  reset()
  answers["eth_gasPrice"] = %*{"ok": true, "route": "direct"}
  discard raisesRpc(proc() = discard rpcGasPrice(Ep))

# ── 4. every read decodes the platform's JSON ─────────────────────────────────
block:
  reset()
  answer("eth_getBalance", %"0xde0b6b3a7640000", "verified")      # 1 ether
  doAssert rpcBalance(Ep, Alice, "latest") == "1000000000000000000"
  doAssert seen[^1].params == %*[Alice, "latest"]
  let b = rpcBalanceRouted(Ep, Alice, "latest")
  doAssert b.value == "1000000000000000000" and b.route == "verified"

  answer("eth_call", %"0x0000000000000000000000000000000000000000000000000000000000000012")
  let ret = rpcCall(Ep, "0x" & repeat("11", 20), @[byte 0x31, 0x3c, 0xe5, 0x67], "latest")
  doAssert ret.len == 32 and ret[31] == 0x12
  doAssert seen[^1].params == %*[{"to": "0x" & repeat("11", 20), "data": "0x313ce567"}, "latest"]

  answer("eth_gasPrice", %"0x3b9aca00")
  doAssert rpcGasPrice(Ep) == 1_000_000_000'u64
  answer("eth_chainId", %"0xaa36a7")
  doAssert rpcChainId(Ep) == "11155111"

  answer("eth_getTransactionCount", %"0x7")
  doAssert rpcNonce(Ep, Alice) == 7'u64 and seen[^1].params == %*[Alice, "pending"]
  doAssert rpcNonceMined(Ep, Alice) == 7'u64 and seen[^1].params == %*[Alice, "latest"]

  answer("eth_getTransactionReceipt", newJNull())
  doAssert rpcReceiptStatus(Ep, TxHash) == -1, "no receipt yet is pending"
  answer("eth_getTransactionReceipt", %*{"status": "0x1", "logs": []})
  doAssert rpcReceiptStatus(Ep, TxHash) == 1
  answer("eth_getTransactionReceipt", %*{"status": "0x0", "logs": []})
  doAssert rpcReceiptStatus(Ep, TxHash) == 0

  answer("eth_getTransactionByHash", newJNull())
  doAssert not rpcTransferOf(Ep, TxHash).found, "an unknown transaction is not known"
  answer("eth_getTransactionByHash", %*{"from": Alice, "to": "0x" & repeat("22", 20),
                                         "value": "0x2386f26fc10000", "blockNumber": "0x1f"})
  answer("eth_getTransactionReceipt", %*{"status": "0x1", "logs": []})
  let t = rpcTransferOf(Ep, TxHash)
  doAssert t.found and t.fromHex == Alice and t.toHex == "0x" & repeat("22", 20)
  doAssert t.valueDec == "10000000000000000" and t.status == 1 and t.blockNumber == 31'u64
  answer("eth_getTransactionByHash", %*{"from": Alice, "to": nil, "value": "0x0",
                                         "blockNumber": nil})
  answer("eth_getTransactionReceipt", newJNull())
  let c = rpcTransferOf(Ep, TxHash)
  doAssert c.found and c.toHex == "" and c.status == -1 and c.blockNumber == 0'u64

  let topic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  answer("eth_getTransactionReceipt", %*{"status": "0x1", "logs": [
    {"address": "0x" & repeat("33", 20), "topics": [topic], "data": "0x01"}]})
  let lg = rpcReceiptLogs(Ep, TxHash)
  doAssert lg.found and lg.status == 1 and lg.logs.len == 1
  doAssert lg.logs[0].address == "0x" & repeat("33", 20) and lg.logs[0].topics == @[topic]
  doAssert lg.logs[0].data == "0x01"
  answer("eth_getTransactionReceipt", newJNull())
  doAssert not rpcReceiptLogs(Ep, TxHash).found

  answer("eth_getProof", %*{"nonce": "0x2", "balance": "0x64",
    "storageHash": "0x" & repeat("44", 32), "codeHash": "0x" & repeat("55", 32),
    "accountProof": ["0xf8", "0xe2a0"]})
  let pr = rpcGetProof(Ep, Alice, "0x10")
  doAssert pr.nonce == 2'u64 and pr.balanceDec == "100"
  doAssert pr.storageHashHex == "0x" & repeat("44", 32) and pr.codeHashHex == "0x" & repeat("55", 32)
  doAssert pr.proof == @[@[byte 0xf8], @[byte 0xe2, 0xa0]]
  doAssert seen[^1].params == %*[Alice, newJArray(), "0x10"]

  answer("eth_sendRawTransaction", %TxHash, "proxied")
  doAssert rpcSendRaw(Ep, @[byte 0x02, 0xf8]) == TxHash
  doAssert seen[^1].params == %*["0x02f8"]

# ── 5. nothing on the platform signs for muster ───────────────────────────────
block:
  reset()
  let m = raisesRpc(proc() = discard rpcSendTransaction(Ep, Alice, Alice, 1.u256, @[], 21000))
  doAssert "unlocked" in m, m
  doAssert seen.len == 0, "refused before anything is sent"

# ── 6. the Safe reads take the same path ──────────────────────────────────────
block:
  reset()
  answer("eth_chainId", %"0xaa36a7")
  let p = probeRpc(Ep)
  doAssert p.ok and p.chainId == Sepolia
  var safeAddr: Address
  for i in 0 ..< 20: safeAddr[i] = 0x66
  # getThreshold(): uint256 2
  answer("eth_call", %("0x" & repeat("0", 63) & "2"))
  let th = getThreshold(Ep, safeAddr)
  doAssert th.known and th.threshold == 2
  doAssert seen[^1].meth == "eth_call" and seen[^1].chainId == Sepolia
  refuse("eth_call", "http: connection refused")
  doAssert not getThreshold(Ep, safeAddr).known
  refuse("eth_chainId", "http: connection refused")
  doAssert not probeRpc(Ep).ok

# ── 7. the person's chain registry ────────────────────────────────────────────
block:
  # list_chain_configs as eth_rpc_module answers it (rpc.rs @42cc465): mainnets first, each
  # row its own inScope verdict against the device-wide scope
  let reg = parseChainConfigs(%*{"ok": true, "scope": "testnets", "chains": [
    {"chainId": 1, "name": "Ethereum", "testnet": false, "enabled": true, "inScope": false},
    {"chainId": 11155111, "name": "Sepolia", "testnet": true, "enabled": true, "inScope": true},
    {"chainId": 560048, "name": "Hoodi", "testnet": true, "enabled": false, "inScope": true},
    {"chainId": 0, "name": "broken"}]})
  doAssert reg.ok and reg.scope == "testnets" and reg.chains.len == 3, "a row with no chain id is dropped"
  var offeredIds: seq[int]
  for c in reg.chains:
    if c.offered: offeredIds.add c.chainId
  doAssert offeredIds == @[Sepolia], "offered = enabled and in the person's scope"
  doAssert not parseChainConfigs(%*{"ok": false, "error": "eth_rpc not initialized"}).ok
  doAssert not parseChainConfigs(nil).ok

# ── 8. when the registry is read again ────────────────────────────────────────
block:
  # Answered: every 30 s. Unanswered: soon, then less often. Basecamp starts muster_module
  # and eth_rpc_module side by side, so the first read can come before eth_rpc_module
  # answers; a flat 5 min wait left that person on the URL path for 5 minutes (R6,
  # 2026-10-07). A host with no eth_rpc_module (the runner) settles at the 5 min cap.
  doAssert registryRecheckS(true, 0) == 30.0
  doAssert registryRecheckS(false, 1) == 2.0, "the first miss is retried within seconds"
  doAssert registryRecheckS(false, 2) == 4.0
  doAssert registryRecheckS(false, 3) == 8.0
  doAssert registryRecheckS(false, 9) == 300.0 and registryRecheckS(false, 50) == 300.0,
    "capped at 5 min, never overflowing"
  var waited = 0.0
  for n in 1 .. 8: waited += registryRecheckS(false, n)
  doAssert waited < 600.0, "a host without the module pays few reads in its first 10 min"

echo "chain_endpoint_test: ok"
