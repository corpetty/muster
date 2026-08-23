## The EVM JSON-RPC calls, over **nim-web3** (Status/Nimbus) — typed `eth_*` methods
## instead of hand-built JSON-RPC + hex parsing. nim-web3 is async (chronos), so
## each call is driven synchronously with `waitFor`; this module is the seam that
## isolates chronos, web3, and the eth types from the rest of the wallet, exposing
## plain sync procs over strings/bytes. A transport or JSON-RPC error becomes a
## raised WalletError — a failed call never returns a value a caller could trust.
##
## We import `web3/eth_api` + `json_rpc/clients/httpclient` directly (not top-level
## `web3`), which keeps websock off the dependency closure.

import std/typetraits
import chronos
import stint
import json_rpc/clients/httpclient
import web3/[eth_api, eth_api_types]
import eth/common/[addresses, hashes]
import ./types

proc q(x: Quantity): uint64 = uint64(distinctBase(x))

proc connected(url: string): RpcHttpClient =
  result = newRpcHttpClient()
  try: waitFor result.connect(url)
  except CatchableError as e:
    raise newException(WalletError, "web3 connect failed: " & e.msg)

proc done(c: RpcHttpClient) =
  try: waitFor c.close()
  except CatchableError: discard

proc rpcBalance*(url, addrHex, tag: string): string =
  ## Native balance, decimal base units (wei) — typed UInt256, no hex parsing.
  let c = connected(url)
  defer: c.done()
  try: $(waitFor c.eth_getBalance(Address.fromHex(addrHex), tag))
  except CatchableError as e: raise newException(WalletError, "eth_getBalance: " & e.msg)

proc rpcCall*(url, toHex: string, data: seq[byte], tag: string): seq[byte] =
  ## eth_call (e.g. ERC-20 balanceOf) → the ABI-encoded return bytes.
  let c = connected(url)
  defer: c.done()
  let args = TransactionArgs(to: Opt.some(Address.fromHex(toHex)), data: Opt.some(data))
  try: waitFor c.eth_call(args, tag)
  except CatchableError as e: raise newException(WalletError, "eth_call: " & e.msg)

proc rpcGasPrice*(url: string): uint64 =
  let c = connected(url)
  defer: c.done()
  try: q(waitFor c.eth_gasPrice())
  except CatchableError as e: raise newException(WalletError, "eth_gasPrice: " & e.msg)

proc rpcNonce*(url, addrHex: string): uint64 =
  let c = connected(url)
  defer: c.done()
  try: q(waitFor c.eth_getTransactionCount(Address.fromHex(addrHex), "pending"))
  except CatchableError as e: raise newException(WalletError, "eth_getTransactionCount: " & e.msg)

proc rpcSendRaw*(url: string, raw: seq[byte]): string =
  let c = connected(url)
  defer: c.done()
  try: (waitFor c.eth_sendRawTransaction(raw)).to0xHex
  except CatchableError as e: raise newException(WalletError, "eth_sendRawTransaction: " & e.msg)

proc rpcReceiptStatus*(url, txHashHex: string): int =
  ## 1 = success, 0 = failed, -1 = no receipt yet (pending). A pending tx has no
  ## receipt; we report that rather than raising.
  let c = connected(url)
  defer: c.done()
  try:
    let r = waitFor c.eth_getTransactionReceipt(Hash32.fromHex(txHashHex))
    if r.status.isSome: (if q(r.status.get) == 1: 1 else: 0) else: -1
  except CatchableError:
    -1

proc rpcSendTransaction*(url, fromHex, toHex: string, value: UInt256,
                         data: seq[byte], gas: uint64): string =
  ## anvil-unlocked path: the node signs for an unlocked `from`. Returns the tx hash.
  let c = connected(url)
  defer: c.done()
  let args = TransactionArgs(
    `from`: Opt.some(Address.fromHex(fromHex)), to: Opt.some(Address.fromHex(toHex)),
    value: Opt.some(value), data: Opt.some(data), gas: Opt.some(Quantity(gas)))
  try: (waitFor c.eth_sendTransaction(args)).to0xHex
  except CatchableError as e: raise newException(WalletError, "eth_sendTransaction: " & e.msg)

proc rpcGetProof*(url, addrHex, tag: string):
    tuple[nonce: uint64, balanceDec, storageHashHex, codeHashHex: string, proof: seq[seq[byte]]] =
  ## eth_getProof — typed ProofResponse. The account fields + the accountProof
  ## nodes, for verifying against a trusted state root (verify.nim).
  let c = connected(url)
  defer: c.done()
  try:
    let pr = waitFor c.eth_getProof(Address.fromHex(addrHex), newSeq[UInt256](0), tag)
    var nodes: seq[seq[byte]]
    for n in pr.accountProof: nodes.add distinctBase(n)
    (q(pr.nonce), $pr.balance, pr.storageHash.to0xHex, pr.codeHash.to0xHex, nodes)
  except CatchableError as e:
    raise newException(WalletError, "eth_getProof: " & e.msg)
