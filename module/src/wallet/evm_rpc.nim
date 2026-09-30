## The EVM JSON-RPC calls, over **nim-web3** (Status/Nimbus) — typed `eth_*` methods
## instead of hand-built JSON-RPC + hex parsing. nim-web3 is async (chronos), so
## each call is driven synchronously with `waitFor`; this module is the seam that
## isolates chronos, web3, and the eth types from the rest of the wallet, exposing
## plain sync procs over strings/bytes. A transport or JSON-RPC error becomes a
## raised WalletError — a failed call never returns a value a caller could trust.
##
## We import `web3/eth_api` + `json_rpc/clients/httpclient` directly (not top-level
## `web3`), which keeps websock off the dependency closure.

import std/[typetraits, tables]
import chronos
import stint
import json_rpc/clients/httpclient
import web3/[eth_api, eth_api_types]
import eth/common/[addresses, hashes]
import ./types
import ./erc20_logs

proc q(x: Quantity): uint64 = uint64(distinctBase(x))

# One connected client per endpoint, reused across calls — connecting on every
# call is the latency we don't want under a UI. A call that fails evicts its
# client so the next call reconnects fresh (a dropped keep-alive heals itself).
var gClients: Table[string, RpcHttpClient]

proc getClient(url: string): RpcHttpClient =
  if url notin gClients:
    let c = newRpcHttpClient()
    try: waitFor c.connect(url)
    except CatchableError as e:
      raise newException(WalletError, "web3 connect failed: " & e.msg)
    gClients[url] = c
  gClients[url]

proc evict(url: string) =
  if url in gClients:
    let c = gClients[url]
    gClients.del(url)
    try: waitFor c.close()
    except CatchableError: discard

template rpcTry(url, label: string, body: untyped): untyped =
  ## Run a web3 call on the cached client; on any failure, evict the client and
  ## raise WalletError — a failed call never returns a value a caller could trust.
  let c {.inject.} = getClient(url)
  try: body
  except CatchableError as e:
    evict(url)
    raise newException(WalletError, label & ": " & e.msg)

proc rpcBalance*(url, addrHex, tag: string): string =
  ## Native balance, decimal base units (wei) — typed UInt256, no hex parsing.
  rpcTry(url, "eth_getBalance"):
    $(waitFor c.eth_getBalance(Address.fromHex(addrHex), tag))

proc rpcCall*(url, toHex: string, data: seq[byte], tag: string): seq[byte] =
  ## eth_call (e.g. ERC-20 balanceOf) → the ABI-encoded return bytes.
  rpcTry(url, "eth_call"):
    waitFor c.eth_call(TransactionArgs(to: Opt.some(Address.fromHex(toHex)),
                                       data: Opt.some(data)), tag)

proc rpcGasPrice*(url: string): uint64 =
  rpcTry(url, "eth_gasPrice"):
    q(waitFor c.eth_gasPrice())

proc rpcChainId*(url: string): string =
  ## The chain id this endpoint serves, decimal — so a payment is never sent, nor a
  ## payment confirmed, through an RPC serving another chain than the one agreed (exo-a90.5).
  rpcTry(url, "eth_chainId"):
    $(waitFor c.eth_chainId())

proc rpcNonce*(url, addrHex: string): uint64 =
  rpcTry(url, "eth_getTransactionCount"):
    q(waitFor c.eth_getTransactionCount(Address.fromHex(addrHex), "pending"))

proc rpcNonceMined*(url, addrHex: string): uint64 =
  ## The account's nonce counted over mined transactions only ("latest").
  rpcTry(url, "eth_getTransactionCount"):
    q(waitFor c.eth_getTransactionCount(Address.fromHex(addrHex), "latest"))

proc rpcSendRaw*(url: string, raw: seq[byte]): string =
  rpcTry(url, "eth_sendRawTransaction"):
    (waitFor c.eth_sendRawTransaction(raw)).to0xHex

proc rpcReceiptStatus*(url, txHashHex: string): int =
  ## 1 = success, 0 = failed, -1 = no receipt yet (pending). A pending tx has no
  ## receipt; that is reported, not raised.
  let cl = getClient(url)
  try:
    let r = waitFor cl.eth_getTransactionReceipt(Hash32.fromHex(txHashHex))
    # no receipt yet comes back as nil — pending, not a crash (exo-a50.1.5: this was a
    # SIGSEGV the first time finality was watched through the adapter)
    if r.isNil: return -1
    if r.status.isSome: (if q(r.status.get) == 1: 1 else: 0) else: -1
  except CatchableError:
    evict(url); -1

proc rpcTransferOf*(url, txHashHex: string):
    tuple[found: bool, fromHex, toHex, valueDec: string, status: int, blockNumber: uint64] =
  ## What a transaction moved, as THIS endpoint reports it (exo-a90.4: a creditor reading a
  ## reported payment): sender, receiver ("" for a contract creation), native value in wei,
  ## and its receipt status (1 success, 0 failed, -1 no receipt yet). found = false when the
  ## node knows no such transaction. A transport error raises — never reads as "not found".
  let tx = rpcTry(url, "eth_getTransactionByHash"):
    waitFor c.eth_getTransactionByHash(Hash32.fromHex(txHashHex))
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
  let r = rpcTry(url, "eth_getTransactionReceipt"):
    waitFor c.eth_getTransactionReceipt(Hash32.fromHex(txHashHex))
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
  rpcTry(url, "eth_sendTransaction"):
    waitFor(c.eth_sendTransaction(TransactionArgs(
      `from`: Opt.some(Address.fromHex(fromHex)), to: Opt.some(Address.fromHex(toHex)),
      value: Opt.some(value), data: Opt.some(data), gas: Opt.some(Quantity(gas))))).to0xHex

proc rpcGetProof*(url, addrHex, tag: string):
    tuple[nonce: uint64, balanceDec, storageHashHex, codeHashHex: string, proof: seq[seq[byte]]] =
  ## eth_getProof — typed ProofResponse. The account fields + the accountProof
  ## nodes, for verifying against a trusted state root (verify.nim).
  rpcTry(url, "eth_getProof"):
    let pr = waitFor c.eth_getProof(Address.fromHex(addrHex), newSeq[UInt256](0), tag)
    var nodes: seq[seq[byte]]
    for n in pr.accountProof: nodes.add distinctBase(n)
    (q(pr.nonce), $pr.balance, pr.storageHash.to0xHex, pr.codeHash.to0xHex, nodes)
