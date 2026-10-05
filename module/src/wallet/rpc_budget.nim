## A budget for every chain call (exo-14f).
##
## muster_module dispatches every call synchronously on ONE thread (nim-lib/muster_gen.nim;
## docs/labbook/chronos-waitfor-at-the-sync-boundary.md), and every RPC endpoint it calls is
## the user's own, untrusted infrastructure (invariant 8). An endpoint that accepts a
## connection and never answers would hold that thread, and every UI call queued behind it,
## for as long as it liked. So no chain call waits without a budget: each is a chronos future
## driven under `wait(budget)`, ONE deadline over connect, request, headers and body. Past
## the budget the call is cancelled and raises RpcTimeoutError: an error, never a value.
##
## std/httpclient is not used for this: its `timeout` bounds each recv only, and its connect
## not at all, so an address that drops SYNs hangs it for the OS's TCP timeout (~2 min).
##
## Not bounded: resolving a hostname, which the OS resolver does synchronously before the
## first byte is sent (its own timeout applies).

import std/json
import chronos
import json_rpc/clients/httpclient

export Duration, seconds, milliseconds

type
  RpcError* = object of CatchableError   ## the endpoint failed: unreachable, refused, an RPC error, no answer
  RpcTimeoutError* = object of RpcError  ## no answer within the call's budget

const
  ReadBudget* = 5.seconds            ## a read: a balance, an owner set, a nonce, a receipt
  SendBudget* = 30.seconds           ## a broadcast, as btc_adapter's: a node may validate before it answers
  ProbeBudget* = 1500.milliseconds   ## a liveness probe (eth_chainId): reachable quickly, or down
  ScanBudget* = 5.minutes            ## bitcoind's scantxoutset: one pass over every coin in the node's
                                     ## UTXO set, over 10^8 on mainnet (Core gives it a "status" action
                                     ## that reports progress); a regtest node answers at once. Its
                                     ## connect still gets a read's budget (btc_adapter.call),
                                     ## so only a node that took the request holds the thread this long.
  CloseBudget = 2.seconds            ## dropping a client must not hang either

var budgets = (read: ReadBudget, send: SendBudget, probe: ProbeBudget, scan: ScanBudget)

proc readBudget*(): Duration = budgets.read
proc sendBudget*(): Duration = budgets.send
proc probeBudget*(): Duration = budgets.probe
proc scanBudget*(): Duration = budgets.scan

proc setRpcBudgets*(read = ReadBudget, send = SendBudget, probe = ProbeBudget, scan = ScanBudget) =
  ## Only tests shrink these, to prove a hung endpoint fails within one. With no
  ## arguments, the defaults again.
  budgets = (read: read, send: send, probe: probe, scan: scan)

template bounded*(fut: untyped, budget: Duration): untyped =
  ## `waitFor fut`, within `budget`: past it `fut` is cancelled and RpcTimeoutError raised.
  ## Only on the module dispatch thread, like any waitFor (the labbook above).
  try:
    waitFor wait(fut, budget)
  except AsyncTimeoutError:
    raise newException(RpcTimeoutError, "no answer within " & $budget)

proc closeQuietly*(c: RpcClient) =
  ## Drop a client within CloseBudget. A close that fails or hangs is abandoned, never raised:
  ## the call it ends has already failed with its own reason.
  if c == nil: return
  try: discard waitFor c.close().withTimeout(CloseBudget)   # cancels the close past the budget
  except CatchableError: discard

proc rpcErrorText(msg: string): string =
  ## nim-json-rpc raises an RPC error with the error object, encoded, as its message.
  try:
    let j = parseJson(msg)
    if j.kind == JObject and j.hasKey("message"): return j["message"].getStr(msg)
  except CatchableError: discard
  msg

proc jsonRpc*(url, meth: string, params: JsonNode, budget: Duration): JsonNode =
  ## One JSON-RPC call to `url` on a fresh client, within `budget` → its `result`, JNull when
  ## the endpoint answered null (whether null is an answer is the caller's to say). A
  ## transport failure, an RPC error, or no answer within the budget raises RpcError. The url
  ## is never in the message: it may carry credentials.
  let deadline = Moment.fromNow(budget)
  proc left(): Duration = max(deadline - Moment.now(), ZeroDuration)
  let c = newRpcHttpClient()
  try:
    bounded(c.connect(url), left())
    parseJson(string(bounded(c.call(meth, params), left())))
  except RpcTimeoutError:
    raise newException(RpcTimeoutError, meth & ": no answer within " & $budget)
  except CatchableError as e:
    raise newException(RpcError, meth & ": " & rpcErrorText(e.msg))
  finally:
    closeQuietly(c)
