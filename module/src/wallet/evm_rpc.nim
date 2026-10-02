## The EVM JSON-RPC calls, over **nim-web3** (Status/Nimbus) — typed `eth_*` methods
## instead of hand-built JSON-RPC + hex parsing. nim-web3 is async (chronos), so
## each call is driven synchronously with `waitFor`; this module is the seam that
## isolates chronos, web3, and the eth types from the rest of the wallet, exposing
## plain sync procs over strings/bytes. A transport or JSON-RPC error becomes a
## raised WalletError — a failed call never returns a value a caller could trust. Every
## call runs within a budget (wallet/rpc_budget.nim, exo-14f): a read within the read
## budget, a broadcast within the send budget, so a hung endpoint never holds the module.
## After a no-answer the endpoint cools down (exo-14f.1): a read raises at once, saying
## when it is tried again; a broadcast is always sent.
##
## We import `web3/eth_api` + `json_rpc/clients/httpclient` directly (not top-level
## `web3`), which keeps websock off the dependency closure.
##
## An endpoint may instead name the platform's eth_rpc_module (`logos:eth_rpc_module/<id>`,
## wallet/chain_endpoint.nim, exo-d4d.3): then each call goes there as plain JSON-RPC and is
## decoded here the way nim-web3 decodes a URL's answer, so a caller cannot tell the two
## apart except by the route a read reports.

import std/[typetraits, tables]
import chronos
import stint
import json_rpc/clients/httpclient
import web3/[eth_api, eth_api_types]
import eth/common/[addresses, hashes]
import ./types
import ./erc20_logs
import ./rpc_budget
import ./chain_endpoint
import std/[json, strutils]

proc q(x: Quantity): uint64 = uint64(distinctBase(x))

# ── the platform path (eth_rpc_module) ────────────────────────────────────────
proc pcall(url, meth: string, params: JsonNode, budget = readBudget()): RoutedResult =
  ## One call through eth_rpc_module; any failure is a WalletError, as on the URL path.
  try: chainRpc(url, meth, params, budget)
  except RpcError as e: raise newException(WalletError, e.msg)

proc hexStr(j: JsonNode, what: string): string =
  ## A value that must be 0x-hex text. Null or anything else raises: never read as zero.
  if j == nil or j.kind != JString or not j.getStr().startsWith("0x"):
    raise newException(WalletError, what & ": no value (" & (if j == nil: "nil" else: $j) & ")")
  j.getStr()

proc hexU64(j: JsonNode, what: string): uint64 =
  let h = hexStr(j, what)
  try: (if h.len == 2: 0'u64 else: fromHex[uint64](h))
  except ValueError: raise newException(WalletError, what & ": not a quantity " & h)

proc hexDec(j: JsonNode, what: string): string =
  ## A 256-bit quantity, as decimal text (wei).
  let h = hexStr(j, what)
  try: $(if h.len == 2: 0.u256 else: UInt256.fromHex(h))
  except CatchableError: raise newException(WalletError, what & ": not a quantity " & h)

proc hexBytes(j: JsonNode, what: string): seq[byte] =
  let h = hexStr(j, what)[2 .. ^1]
  if h.len mod 2 != 0: raise newException(WalletError, what & ": odd-length hex")
  try:
    for i in countup(0, h.len - 2, 2): result.add byte(parseHexInt(h[i .. i + 1]))
  except ValueError: raise newException(WalletError, what & ": not hex")

proc hex0x(b: openArray[byte]): string =
  result = "0x"
  for x in b: result.add toHex(x, 2).toLowerAscii()

proc receiptStatusOf(r: JsonNode): int =
  ## 1 success, 0 failed, -1 no status (a pre-Byzantium receipt, or none).
  if r.kind != JObject or not r.hasKey("status") or r["status"].kind != JString: return -1
  if hexU64(r["status"], "receipt status") == 1: 1 else: 0

# One connected client per endpoint, reused across calls — connecting on every
# call is the latency we don't want under a UI. A call that fails evicts its
# client so the next call reconnects fresh (a dropped keep-alive heals itself).
var gClients: Table[string, RpcHttpClient]

proc getClient(url: string): RpcHttpClient =
  if url notin gClients:
    let c = newRpcHttpClient()
    try: bounded(c.connect(url), readBudget())
    except RpcTimeoutError as e:
      closeQuietly(c)
      raise e                  # a no-answer stays one: the endpoint's cooldown starts on it
    except CatchableError as e:
      closeQuietly(c)
      raise newException(WalletError, "web3 connect failed: " & e.msg)
    gClients[url] = c
  gClients[url]

proc evict(url: string) =
  if url in gClients:
    let c = gClients[url]
    gClients.del(url)
    closeQuietly(c)

template rpcTry(url, label: string, send: bool, body: untyped): untyped =
  ## Run a web3 call on the cached client, under the endpoint's cooldown (`send`: a
  ## broadcast, always sent); on any failure, evict the client and raise WalletError — a
  ## failed call never returns a value a caller could trust.
  try:
    onEndpoint(url, label, send):
      let c {.inject.} = getClient(url)
      body
  except CatchableError as e:
    evict(url)
    raise newException(WalletError, label & ": " & e.msg)

proc rpcBalance*(url, addrHex, tag: string): string =
  ## Native balance, decimal base units (wei) — typed UInt256, no hex parsing.
  if url.isPlatform: return hexDec(pcall(url, "eth_getBalance", %*[addrHex, tag]).result, "eth_getBalance")
  rpcTry(url, "eth_getBalance", false):
    $bounded(c.eth_getBalance(Address.fromHex(addrHex), tag), readBudget())

proc rpcCall*(url, toHex: string, data: seq[byte], tag: string): seq[byte] =
  ## eth_call (e.g. ERC-20 balanceOf) → the ABI-encoded return bytes.
  if url.isPlatform:
    return hexBytes(pcall(url, "eth_call", %*[{"to": toHex, "data": hex0x(data)}, tag]).result, "eth_call")
  rpcTry(url, "eth_call", false):
    bounded(c.eth_call(TransactionArgs(to: Opt.some(Address.fromHex(toHex)),
                                       data: Opt.some(data)), tag), readBudget())

proc rpcBalanceRouted*(url, addrHex, tag: string): tuple[value, route: string] =
  ## A native balance and how it was obtained: "verified" only when eth_rpc_module proved it
  ## against a light-client header (F-10); a URL's balance is "direct".
  if url.isPlatform:
    let r = pcall(url, "eth_getBalance", %*[addrHex, tag])
    return (hexDec(r.result, "eth_getBalance"), r.route)
  (rpcBalance(url, addrHex, tag), "direct")

proc rpcGasPrice*(url: string): uint64 =
  if url.isPlatform: return hexU64(pcall(url, "eth_gasPrice", newJArray()).result, "eth_gasPrice")
  rpcTry(url, "eth_gasPrice", false):
    q(bounded(c.eth_gasPrice(), readBudget()))

proc rpcChainId*(url: string): string =
  ## The chain id this endpoint serves, decimal — so a payment is never sent, nor a
  ## payment confirmed, through an RPC serving another chain than the one agreed (exo-a90.5).
  if url.isPlatform: return $hexU64(pcall(url, "eth_chainId", newJArray()).result, "eth_chainId")
  rpcTry(url, "eth_chainId", false):
    $bounded(c.eth_chainId(), readBudget())

proc rpcNonce*(url, addrHex: string): uint64 =
  if url.isPlatform:
    return hexU64(pcall(url, "eth_getTransactionCount", %*[addrHex, "pending"]).result, "eth_getTransactionCount")
  rpcTry(url, "eth_getTransactionCount", false):
    q(bounded(c.eth_getTransactionCount(Address.fromHex(addrHex), "pending"), readBudget()))

proc rpcNonceMined*(url, addrHex: string): uint64 =
  ## The account's nonce counted over mined transactions only ("latest").
  if url.isPlatform:
    return hexU64(pcall(url, "eth_getTransactionCount", %*[addrHex, "latest"]).result, "eth_getTransactionCount")
  rpcTry(url, "eth_getTransactionCount", false):
    q(bounded(c.eth_getTransactionCount(Address.fromHex(addrHex), "latest"), readBudget()))

proc rpcSendRaw*(url: string, raw: seq[byte]): string =
  if url.isPlatform:
    return hexStr(pcall(url, "eth_sendRawTransaction", %*[hex0x(raw)], sendBudget()).result, "eth_sendRawTransaction")
  rpcTry(url, "eth_sendRawTransaction", true):
    bounded(c.eth_sendRawTransaction(raw), sendBudget()).to0xHex

proc rpcReceiptStatus*(url, txHashHex: string): int =
  ## 1 = success, 0 = failed, -1 = no receipt yet (pending). A pending tx has no
  ## receipt; that is reported, not raised. A failed read raises WalletError: it is not
  ## the chain saying "pending", and a caller that would take it as one decides so itself.
  if url.isPlatform: return receiptStatusOf(pcall(url, "eth_getTransactionReceipt", %*[txHashHex]).result)
  let r = rpcTry(url, "eth_getTransactionReceipt", false):
    bounded(c.eth_getTransactionReceipt(Hash32.fromHex(txHashHex)), readBudget())
  # no receipt yet comes back as nil — pending, not a crash (exo-a50.1.5: this was a
  # SIGSEGV the first time finality was watched through the adapter)
  if r.isNil: return -1
  if r.status.isSome: (if q(r.status.get) == 1: 1 else: 0) else: -1

proc rpcTransferOf*(url, txHashHex: string):
    tuple[found: bool, fromHex, toHex, valueDec: string, status: int, blockNumber: uint64] =
  ## What a transaction moved, as THIS endpoint reports it (exo-a90.4: a creditor reading a
  ## reported payment): sender, receiver ("" for a contract creation), native value in wei,
  ## and its receipt status (1 success, 0 failed, -1 no receipt yet). found = false when the
  ## node knows no such transaction. A transport error raises — never reads as "not found".
  if url.isPlatform:
    let tx = pcall(url, "eth_getTransactionByHash", %*[txHashHex]).result
    if tx.kind != JObject: return (false, "", "", "0", -1, 0'u64)
    let to = (if tx{"to"} != nil and tx["to"].kind == JString: tx["to"].getStr() else: "")
    let bn = (if tx{"blockNumber"} != nil and tx["blockNumber"].kind == JString: hexU64(tx["blockNumber"], "blockNumber") else: 0'u64)
    return (true, hexStr(tx{"from"}, "from"), to, hexDec(tx{"value"}, "value"), rpcReceiptStatus(url, txHashHex), bn)
  let tx = rpcTry(url, "eth_getTransactionByHash", false):
    bounded(c.eth_getTransactionByHash(Hash32.fromHex(txHashHex)), readBudget())
  if tx.isNil: return (false, "", "", "0", -1, 0'u64)
  let status = rpcReceiptStatus(url, txHashHex)
  (true, tx.`from`.to0xHex, (if tx.to.isSome: tx.to.get.to0xHex else: ""), $tx.value, status,
   (if tx.blockNumber.isSome: q(tx.blockNumber.get) else: 0'u64))

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc rpcReceiptLogs*(url, txHashHex: string): tuple[found: bool, status: int, logs: seq[RawLog]] =
  ## A transaction's receipt as THIS endpoint reports it: its status (1 success, 0 failed)
  ## and its logs as hex (exo-5ab: a token payment is read from its Transfer log). found =
  ## false while there is no receipt; a transport error raises — never "no logs".
  if url.isPlatform:
    let r = pcall(url, "eth_getTransactionReceipt", %*[txHashHex]).result
    if r.kind != JObject: return (false, -1, @[])
    var logs: seq[RawLog]
    for l in r{"logs"}.getElems():
      var topics: seq[string]
      for t in l{"topics"}.getElems(): topics.add hexStr(t, "log topic")
      logs.add RawLog(address: hexStr(l{"address"}, "log address"), topics: topics, data: hexStr(l{"data"}, "log data"))
    return (true, receiptStatusOf(r), logs)
  let r = rpcTry(url, "eth_getTransactionReceipt", false):
    bounded(c.eth_getTransactionReceipt(Hash32.fromHex(txHashHex)), readBudget())
  if r.isNil: return (false, -1, @[])
  let status = (if r.status.isSome: (if q(r.status.get) == 1: 1 else: 0) else: -1)
  var logs: seq[RawLog]
  for l in r.logs:
    var topics: seq[string]
    for t in l.topics: topics.add hexOf(distinctBase(t))
    logs.add RawLog(address: l.address.to0xHex, topics: topics, data: hexOf(l.data))
  (true, status, logs)

proc rpcSendTransaction*(url, fromHex, toHex: string, value: UInt256,
                         data: seq[byte], gas: uint64): string =
  ## anvil-unlocked path: the node signs for an unlocked `from`. Returns the tx hash.
  if url.isPlatform:
    raise newException(WalletError, "eth_sendTransaction: an unlocked-account send is for a local test chain; nothing on the platform signs for muster")
  rpcTry(url, "eth_sendTransaction", true):
    bounded(c.eth_sendTransaction(TransactionArgs(
      `from`: Opt.some(Address.fromHex(fromHex)), to: Opt.some(Address.fromHex(toHex)),
      value: Opt.some(value), data: Opt.some(data), gas: Opt.some(Quantity(gas)))), sendBudget()).to0xHex

proc rpcGetProof*(url, addrHex, tag: string):
    tuple[nonce: uint64, balanceDec, storageHashHex, codeHashHex: string, proof: seq[seq[byte]]] =
  ## eth_getProof — typed ProofResponse. The account fields + the accountProof
  ## nodes, for verifying against a trusted state root (verify.nim).
  if url.isPlatform:
    let pr = pcall(url, "eth_getProof", %*[addrHex, newJArray(), tag]).result
    if pr.kind != JObject: raise newException(WalletError, "eth_getProof: no proof")
    var nodes: seq[seq[byte]]
    for n in pr{"accountProof"}.getElems(): nodes.add hexBytes(n, "accountProof")
    return (hexU64(pr{"nonce"}, "nonce"), hexDec(pr{"balance"}, "balance"),
            hexStr(pr{"storageHash"}, "storageHash"), hexStr(pr{"codeHash"}, "codeHash"), nodes)
  rpcTry(url, "eth_getProof", false):
    let pr = bounded(c.eth_getProof(Address.fromHex(addrHex), newSeq[UInt256](0), tag), readBudget())
    var nodes: seq[seq[byte]]
    for n in pr.accountProof: nodes.add distinctBase(n)
    (q(pr.nonce), $pr.balance, pr.storageHash.to0xHex, pr.codeHash.to0xHex, nodes)
