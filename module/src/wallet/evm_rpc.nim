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

proc rpcNonce*(url, addrHex: string): uint64 =
  rpcTry(url, "eth_getTransactionCount"):
    q(waitFor c.eth_getTransactionCount(Address.fromHex(addrHex), "pending"))

proc rpcSendRaw*(url: string, raw: seq[byte]): string =
  rpcTry(url, "eth_sendRawTransaction"):
    (waitFor c.eth_sendRawTransaction(raw)).to0xHex

proc rpcReceiptStatus*(url, txHashHex: string): int =
  ## 1 = success, 0 = failed, -1 = no receipt yet (pending). A pending tx has no
  ## receipt; that is reported, not raised.
  let cl = getClient(url)
  try:
    let r = waitFor cl.eth_getTransactionReceipt(Hash32.fromHex(txHashHex))
    if r.status.isSome: (if q(r.status.get) == 1: 1 else: 0) else: -1
  except CatchableError:
    evict(url); -1

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
