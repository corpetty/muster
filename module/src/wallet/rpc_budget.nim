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
##
## A budget bounds ONE call; the calls stack (exo-14f.1). coordinate_accounts reads every
## disclosed account every 10 s (a probe, then one or two reads each), connectivity probes
## every 5 s, and the pumps on the intents tick read receipts every 2 s. Against a node
## that answers eth_chainId but holds eth_call, each of those costs its full budget, and
## the module is busy for most of every window. So an endpoint that gives no answer
## within a budget COOLS DOWN: for a short time, a read or a probe to it is not sent and
## raises RpcCoolingError at once. That error is an RpcTimeoutError, never a value: it
## names the call that went unanswered, when, and when the endpoint is tried again. The
## first call after the cooldown is sent. Any successful answer ends the cooldown. Each
## no-answer in a row doubles the next cooldown, from Cooldown up to CooldownCap, so a
## node that is down for an hour costs one budget a minute, not one every 15 s.
##
## A broadcast (`send`) is always sent: it is the user's own action, never a poll, and
## muster does not refuse it on the strength of an earlier read. Its no-answer starts a
## cooldown for the reads all the same. Cooldowns are keyed by the endpoint's URL, held
## in memory, and never written into a message: a URL may carry credentials.

import std/[json, tables]
from std/times import nil    # the wall clock, for messages only; chronos has its own Duration
import chronos
import json_rpc/clients/httpclient

export Duration, seconds, milliseconds

type
  RpcError* = object of CatchableError   ## the endpoint failed: unreachable, refused, an RPC error, no answer
  RpcTimeoutError* = object of RpcError  ## no answer within the call's budget
    budget*: Duration                    ## the budget it had
  RpcCoolingError* = object of RpcTimeoutError
    ## not sent: the endpoint gave no answer a moment ago and is cooling down
    reason*: string                      ## "did not answer eth_call within 5s at 14:02:11; next try at 14:02:26"

const
  ReadBudget* = 5.seconds            ## a read: a balance, an owner set, a nonce, a receipt
  SendBudget* = 30.seconds           ## a broadcast, as btc_adapter's: a node may validate before it answers
  ProbeBudget* = 1500.milliseconds   ## a liveness probe (eth_chainId): reachable quickly, or down
  ScanBudget* = 5.minutes            ## bitcoind's scantxoutset: one pass over every coin in the node's
                                     ## UTXO set, over 10^8 on mainnet (Core gives it a "status" action
                                     ## that reports progress); a regtest node answers at once. Its
                                     ## connect still gets a read's budget (btc_adapter.call),
                                     ## so only a node that took the request holds the thread this long.
  Cooldown* = 15.seconds             ## after a no-answer: more than one accounts poll (10 s) is skipped
  CooldownCap* = 60.seconds          ## the longest cooldown, so a recovered node is used within a minute
  CloseBudget = 2.seconds            ## dropping a client must not hang either

var budgets = (read: ReadBudget, send: SendBudget, probe: ProbeBudget, scan: ScanBudget,
               cooldown: Cooldown, cooldownCap: CooldownCap)

proc readBudget*(): Duration = budgets.read
proc sendBudget*(): Duration = budgets.send
proc probeBudget*(): Duration = budgets.probe
proc scanBudget*(): Duration = budgets.scan

proc setRpcBudgets*(read = ReadBudget, send = SendBudget, probe = ProbeBudget, scan = ScanBudget,
                    cooldown = Cooldown, cooldownCap = CooldownCap) =
  ## Only tests shrink these, to prove a hung endpoint fails within one. With no
  ## arguments, the defaults again. A zero cooldown turns the cooldown off.
  budgets = (read: read, send: send, probe: probe, scan: scan,
             cooldown: cooldown, cooldownCap: cooldownCap)

proc timeoutError(msg: string, budget: Duration): ref RpcTimeoutError =
  result = newException(RpcTimeoutError, msg)
  result.budget = budget

template bounded*(fut: untyped, budget: Duration): untyped =
  ## `waitFor fut`, within `budget`: past it `fut` is cancelled and RpcTimeoutError raised.
  ## Only on the module dispatch thread, like any waitFor (the labbook above).
  try:
    waitFor wait(fut, budget)
  except AsyncTimeoutError:
    raise timeoutError("no answer within " & $budget, budget)

# ── the cooldown ──────────────────────────────────────────────────────────────
type Cooling = object
  strikes: int          ## no-answers in a row
  meth: string          ## the call that went unanswered last
  budget: Duration      ## ...and the budget it had
  at: float             ## when (epoch seconds), for the message
  until: Moment         ## not sent before this (monotonic, so a clock change cannot shorten it)
  untilWall: float      ## the same moment on the wall clock, for the message

var cooling {.threadvar.}: Table[string, Cooling]
  ## endpoint URL → its cooldown. Per thread: every RPC call runs on the module dispatch
  ## thread (the labbook above), and a call from any other thread starts with none.

proc clock(t: float): string = times.format(times.local(times.fromUnixFloat(t)), "HH:mm:ss")

proc reasonOf(c: Cooling): string =
  result = "did not answer " & c.meth & " within " & $c.budget & " at " & clock(c.at)
  if c.strikes > 1: result.add ", " & $c.strikes & " times in a row"
  result.add "; next try at " & clock(c.untilWall)

proc coolingReason*(url: string): string =
  ## Why `url` is cooling down and until when; "" when it is not (the first call after a
  ## cooldown is sent, so an expired one is not cooling).
  if url in cooling and Moment.now() < cooling[url].until: reasonOf(cooling[url]) else: ""

proc refuseWhileCooling*(url: string) =
  ## Raise RpcCoolingError, and send nothing, while `url` is cooling down.
  let reason = coolingReason(url)
  if reason.len == 0: return
  var e = newException(RpcCoolingError, "not sent: the endpoint " & reason)
  e.reason = reason
  e.budget = cooling[url].budget
  raise e

proc unanswered*(url, meth: string, budget: Duration) =
  ## `url` gave no answer to `meth` within `budget`: it cools down, twice as long as last
  ## time if its previous call went unanswered too, up to the cap.
  if budgets.cooldown <= ZeroDuration: return
  var c = cooling.getOrDefault(url)
  inc c.strikes
  var wait = budgets.cooldown
  for _ in 1 ..< c.strikes:
    if wait >= budgets.cooldownCap: break
    wait = wait * 2
  wait = min(wait, budgets.cooldownCap)
  c.meth = meth
  c.budget = budget
  c.at = times.epochTime()
  c.until = Moment.now() + wait
  c.untilWall = c.at + float(wait.milliseconds) / 1000.0
  cooling[url] = c

proc answered*(url: string) =
  ## `url` answered: it is not cooling down, and its next no-answer starts from Cooldown.
  cooling.del(url)

proc forgetCooldown*(url: string) =
  ## `url` is tried at once again: the user has just named it (Settings), which is a
  ## request to use it now, not a poll.
  cooling.del(url)

proc forgetCooldowns*() =
  ## Every endpoint is tried at once again (tests).
  cooling.clear()

template onEndpoint*(url, meth: string, send: bool, body: untyped): untyped =
  ## `body`, one call to `url`, under its cooldown. While it cools down, a read or a probe
  ## raises RpcCoolingError and `body` does not run; a broadcast (`send`) always runs.
  ## A no-answer within the budget starts or lengthens the cooldown; an answer ends it.
  ## Any other failure (refused, an RPC error) leaves it as it is.
  if not send: refuseWhileCooling(url)
  try:
    let answer = body
    answered(url)
    answer
  except RpcTimeoutError as e:
    if not (e of RpcCoolingError): unanswered(url, meth, e.budget)
    raise e

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

proc jsonRpc*(url, meth: string, params: JsonNode, budget: Duration, send = false): JsonNode =
  ## One JSON-RPC call to `url` on a fresh client, within `budget` → its `result`, JNull when
  ## the endpoint answered null (whether null is an answer is the caller's to say). A
  ## transport failure, an RPC error, or no answer within the budget raises RpcError; while
  ## `url` cools down a read raises RpcCoolingError and sends nothing (`send`: a broadcast,
  ## always sent). The url is never in the message: it may carry credentials.
  onEndpoint(url, meth, send):
    let deadline = Moment.fromNow(budget)
    proc left(): Duration = max(deadline - Moment.now(), ZeroDuration)
    # No `finally`: under Nim 2.2.2, raising from an except branch of a try that also has a
    # finally loses the exception object, and the caller's handler dereferences nil
    # (SIGSEGV on any refused connection, exo-14f). The client is closed on each path.
    let c = newRpcHttpClient()
    var answer: JsonNode
    try:
      bounded(c.connect(url), left())
      answer = parseJson(string(bounded(c.call(meth, params), left())))
    except RpcTimeoutError:
      closeQuietly(c)
      raise timeoutError(meth & ": no answer within " & $budget, budget)
    except CatchableError as e:
      closeQuietly(c)
      raise newException(RpcError, meth & ": " & rpcErrorText(e.msg))
    closeQuietly(c)
    answer
