## A hung endpoint costs one budget, never the module thread (exo-14f).
##
## muster_module dispatches every call on one thread, and every RPC endpoint is the user's
## own, untrusted infrastructure (invariant 8). This test stands up, in process, an endpoint
## that ACCEPTS every connection and never replies — what a hung node looks like from the
## client — and holds each chain call of these seams to an error within its budget: the
## Safe reads and broadcast (drivers/safe_rpc.nim), the EVM wallet's (wallet/evm_rpc.nim),
## the LEZ sequencer's (wallet/lez_multisig_live.nim), the finality wait a submit makes
## inside the call (settlement.watchWithin), a payer's landed check (parts_evm), and the
## Bitcoin node's (wallet/btc_adapter.nim, exo-496). A second endpoint answers every call
## with `null`: a read that comes back null raises, never reads as a value (a nonce of 0, a
## balance of "", a height of 0, an empty tx hash) — except where null IS the chain's
## answer (no receipt yet: pending; an unknown transaction: not known). A third answers as
## Bitcoin Core does — an RPC error is HTTP 500 with the error in the body — and the
## node's message must reach the caller, not the status. A fourth address never completes
## a connect (its accept queue is full, so the kernel drops every SYN): the connect is
## bounded too, within a read's budget even for a call given longer.
##
## Budgets are shrunk so the suite stays fast; the mechanism is the one the defaults use.

import std/[json, net, nativesockets, strutils, base64]
import chronos
import stint
import ../src/wallet/rpc_budget
import ../src/wallet/btc_adapter
import ../src/wallet/redact
import ../src/wallet/evm_rpc
import ../src/wallet/types
import ../src/wallet/evm_adapter
import ../src/wallet/lez_multisig_live
import ../src/drivers/safe
import ../src/drivers/safe_rpc
import ../src/settlement/settlement
import ../src/intents/materialization     # PartTransfer
import ../src/coordination/parts_evm

# ── the endpoints ─────────────────────────────────────────────────────────────
proc holdSilently(fd: SocketHandle) {.thread.} =
  ## Accept every connection; never read, never write, never close.
  var held: seq[SocketHandle]
  while true:
    let (c, _) = fd.accept()
    if c != osInvalidSocket: held.add c

proc answerNull(fd: SocketHandle) {.thread.} =
  ## Read each HTTP request and answer its JSON-RPC id with `"result": null`.
  while true:
    let (h, _) = fd.accept()
    if h == osInvalidSocket: continue
    let c = newSocket(h)
    try:
      var length = 0
      while true:
        let line = c.recvLine(timeout = 5000)
        if line.len == 0 or line == "\r\n": break
        if line.toLowerAscii().startsWith("content-length:"): length = parseInt(line.split(':')[1].strip())
      let id = parseJson(c.recv(length, timeout = 5000)){"id"}
      let body = $(%*{"jsonrpc": "2.0", "id": id, "result": newJNull()})
      c.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " & $body.len &
             "\r\nConnection: close\r\n\r\n" & body)
    except CatchableError: discard
    c.close()

const NodeAuth = "Basic " & encode("muster:s3cret")

proc rpcBody(id: JsonNode, err: JsonNode, res = newJNull()): string =
  $(%*{"result": res, "error": err, "id": id})

proc answerAsBitcoind(fd: SocketHandle) {.thread.} =
  ## Answer as Bitcoin Core answers a JSON-RPC 1.0 call: an RPC error is HTTP 500 (404 for
  ## an unknown method) with the error object in the body; a wrong password is HTTP 401
  ## with no body. getwalletinfo answers with the path it reached, so routing shows.
  while true:
    let (h, _) = fd.accept()
    if h == osInvalidSocket: continue
    let c = newSocket(h)
    try:
      let path = c.recvLine(timeout = 5000).split(' ')[1]
      var length = 0
      var auth = ""
      while true:
        let line = c.recvLine(timeout = 5000)
        if line.len == 0 or line == "\r\n": break
        let lower = line.toLowerAscii()
        if lower.startsWith("content-length:"): length = parseInt(line.split(':')[1].strip())
        if lower.startsWith("authorization:"): auth = line.split(':', 1)[1].strip()
      let req = parseJson(c.recv(length, timeout = 5000))
      var status = "200 OK"
      var body = ""
      if auth != NodeAuth: status = "401 Unauthorized"
      else:
        case req{"method"}.getStr()
        of "sendrawtransaction":
          status = "500 Internal Server Error"
          body = rpcBody(req{"id"}, %*{"code": -26, "message": "min relay fee not met, 110 < 141"})
        of "getwalletinfo":
          body = rpcBody(req{"id"}, newJNull(), %*{"path": path})
        of "getblockcount":
          status = "503 Service Unavailable"      # a JSON body with no error object
          body = rpcBody(req{"id"}, newJNull())
        else:
          status = "404 Not Found"
          body = rpcBody(req{"id"}, %*{"code": -32601, "message": "Method not found"})
      c.send("HTTP/1.1 " & status & "\r\nContent-Type: application/json\r\nContent-Length: " &
             $body.len & "\r\nConnection: close\r\n\r\n" & body)
    except CatchableError: discard
    c.close()

var listeners: seq[Socket]
var servers: array[3, Thread[SocketHandle]]

proc serve(i: int, server: proc(fd: SocketHandle) {.thread, nimcall.}): string =
  let s = newSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), "127.0.0.1")
  s.listen()
  listeners.add s
  createThread(servers[i], server, s.getFd())
  "http://127.0.0.1:" & $int(s.getLocalAddr()[1])

let silent = serve(0, holdSilently)
let nulls = serve(1, answerNull)
let coreNode = serve(2, answerAsBitcoind)

proc synDropping(): string =
  ## An address whose connect never completes: a listener that never accepts, its queue
  ## filled by one connection, so the kernel drops every further SYN — from the client,
  ## what an address that drops SYNs looks like (the connect waits for the kernel's TCP
  ## timeout, ~2 min, unless something bounds it).
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  s.listen(0)
  listeners.add s
  let port = s.getLocalAddr()[1]
  let filler = newSocket()
  filler.connect("127.0.0.1", port, timeout = 1000)
  listeners.add filler
  let probe = newSocket()
  try:
    probe.connect("127.0.0.1", port, timeout = 300)
    doAssert false, "the kernel accepted a connect past a full queue: no SYN-dropping address here"
  except TimeoutError: discard
  probe.close()
  "http://127.0.0.1:" & $int(port)

let dropping = synDropping()

# ── the budgets, shrunk ───────────────────────────────────────────────────────
const ReadMs = 400
const SendMs = 800
const ProbeMs = 300
const ScanMs = 1200
const SlackMs = 1500        # scheduling and teardown on a busy machine; the hang it guards is unbounded
setRpcBudgets(read = ReadMs.milliseconds, send = SendMs.milliseconds, probe = ProbeMs.milliseconds,
              scan = ScanMs.milliseconds)

doAssert ReadBudget <= 10.seconds and SendBudget <= 30.seconds and ProbeBudget <= 2.seconds,
  "the defaults stay within what a UI call can wait"
doAssert ScanBudget > SendBudget and ScanBudget <= 10.minutes,
  "a UTXO-set scan gets longer than a broadcast, and still a bound"

var checked = 0
var worstOverMs = 0         # the most any call ran past its budget
proc timed(label: string, budgetMs: int, f: proc(): string, named = "no answer within") =
  ## `f` runs against the silent endpoint and returns the failure it observed ("" if none):
  ## a timeout, named as one, within the budget plus slack — and not before it.
  let t0 = Moment.now()
  let failure = f()
  let ms = int((Moment.now() - t0).milliseconds)
  doAssert failure.len > 0, label & ": returned a value from an endpoint that never answers"
  doAssert named in failure, label & ": failed for another reason: " & failure
  doAssert ms >= budgetMs - 50, label & ": failed after " & $ms & " ms, before its " & $budgetMs & " ms budget"
  doAssert ms <= budgetMs + SlackMs, label & ": took " & $ms & " ms against a " & $budgetMs & " ms budget"
  inc checked
  worstOverMs = max(worstOverMs, ms - budgetMs)

template raisesOn(body: untyped): string =
  ## The message `body` raised with, or "" when it returned.
  var m = ""
  try: discard body
  except CatchableError as e: m.add e.msg   # a copy: `m = e.msg` aliased the message past the
                                            # except block, where ORC frees the exception (ASan)
  m

let safeAddr = Address(default(array[20, byte]))
let zero = "0x0000000000000000000000000000000000000000"
let txh = "0x" & repeat("ab", 32)

# ── 1. the Safe reads and broadcast (drivers/safe_rpc.nim) ─────────────────────
timed("probeRpc", ProbeMs, proc(): string =
  let p = probeRpc(silent)
  doAssert not p.ok
  p.detail)
timed("getOwners", ReadMs, proc(): string =
  let r = getOwners(silent, safeAddr)
  doAssert not r.known and r.owners.len == 0, "an unread owner set is unknown, never empty-and-known"
  r.detail)
timed("getThreshold", ReadMs, proc(): string =
  let r = getThreshold(silent, safeAddr)
  doAssert not r.known
  r.detail)
timed("getModules", ReadMs, proc(): string =
  let r = getModules(silent, safeAddr)
  doAssert not r.known
  r.detail)
timed("getGuard", ReadMs, proc(): string =
  let r = getGuard(silent, safeAddr)
  doAssert not r.known
  r.detail)
timed("safe getBalance", ReadMs, proc(): string = raisesOn(getBalance(silent, safeAddr)))
timed("safeNonce", ReadMs, proc(): string = raisesOn(safeNonce(silent, safeAddr)))
timed("ethCall", ReadMs, proc(): string = raisesOn(ethCall(silent, safeAddr, @[0x01'u8])))
timed("watchReceiptStatus", ReadMs, proc(): string = raisesOn(watchReceiptStatus(silent, txh)))
timed("submitExecTransaction", SendMs, proc(): string =
  raisesOn(submitExecTransaction(silent, safeAddr, safeAddr, @[0x01'u8])))
echo "1. every Safe read and the broadcast fail within their budget on a silent endpoint OK"

# ── 2. the EVM wallet (wallet/evm_rpc.nim) ────────────────────────────────────
timed("rpcBalance", ReadMs, proc(): string = raisesOn(rpcBalance(silent, zero, "latest")))
timed("rpcCall", ReadMs, proc(): string = raisesOn(rpcCall(silent, zero, @[0x01'u8], "latest")))
timed("rpcGasPrice", ReadMs, proc(): string = raisesOn(rpcGasPrice(silent)))
timed("rpcChainId", ReadMs, proc(): string = raisesOn(rpcChainId(silent)))
timed("rpcNonce", ReadMs, proc(): string = raisesOn(rpcNonce(silent, zero)))
timed("rpcNonceMined", ReadMs, proc(): string = raisesOn(rpcNonceMined(silent, zero)))
timed("rpcReceiptStatus", ReadMs, proc(): string = raisesOn(rpcReceiptStatus(silent, txh)))
timed("rpcTransferOf", ReadMs, proc(): string = raisesOn(rpcTransferOf(silent, txh)))
timed("rpcReceiptLogs", ReadMs, proc(): string = raisesOn(rpcReceiptLogs(silent, txh)))
timed("rpcGetProof", ReadMs, proc(): string = raisesOn(rpcGetProof(silent, zero, "latest")))
timed("rpcSendRaw", SendMs, proc(): string = raisesOn(rpcSendRaw(silent, @[0x01'u8])))
timed("rpcSendTransaction", SendMs, proc(): string =
  raisesOn(rpcSendTransaction(silent, zero, zero, 1.u256, @[], 21_000)))
echo "2. every EVM wallet call fails within its budget on a silent endpoint OK"

# ── 3. the LEZ sequencer (wallet/lez_multisig_live.nim) ───────────────────────
let lezSilent = newLezRpc(silent)
timed("lez lastBlockId", ReadMs, proc(): string = raisesOn(lezSilent.lastBlockId()))
timed("lez getAccount", ReadMs, proc(): string = raisesOn(lezSilent.getAccount(newSeq[byte](32))))
timed("lez programId", ReadMs, proc(): string = raisesOn(lezSilent.programId("token")))
timed("lez getTransaction", ReadMs, proc(): string = raisesOn(lezSilent.getTransaction("ab")))
timed("lez sendTransaction", SendMs, proc(): string = raisesOn(lezSilent.sendTransaction(@[0x01'u8])))
echo "3. every LEZ sequencer call fails within its budget on a silent endpoint OK"

# ── 4. a submit's finality wait: the window plus one read, at most ─────────────
block:
  let st = SafeSettlement(family: "evm.safe", adapter: newEvmAdapter("evm:31337", silent))
  let t0 = Moment.now()
  let f = st.watchWithin(TxRef(chain: "evm:31337", id: txh), windowS = 3.0)
  let ms = int((Moment.now() - t0).milliseconds)
  doAssert f.status == fsPending and "no answer within" in f.detail, $f
  doAssert ms <= ReadMs + SlackMs, "a failed read ends the wait at once (took " & $ms & " ms)"
block:
  # a node that answers "no receipt yet" every time: pending, after the window and no longer
  let st = SafeSettlement(family: "evm.safe", adapter: newEvmAdapter("evm:31337", nulls))
  let t0 = Moment.now()
  let f = st.watchWithin(TxRef(chain: "evm:31337", id: txh), windowS = 1.0)
  let ms = int((Moment.now() - t0).milliseconds)
  doAssert f.status == fsPending, $f
  doAssert ms >= 700 and ms <= 1000 + ReadMs + SlackMs, "the wait spans its window (took " & $ms & " ms)"
block:
  # the payer's own check that its share landed (the pending-parts pump): an error, not a
  # crash — the receipt read raises now, and a `case` on it left the result unbuilt
  let seam = newEvmPartSeam("eip155:31337", silent, newEvmAdapter("evm:31337", silent), nil,
                            Account(chain: "eip155:31337", id: zero))
  timed("partLanded", ReadMs, proc(): string = raisesOn(seam.partLanded(PartTransfer(), txh)))
echo "4. a submit's finality wait ends within its window plus one read; a payer's landed check raises OK"

# ── 5. a null read raises, never reads as a value ─────────────────────────────
proc nullRaises(label: string, m: string) =
  doAssert m.len > 0, label & ": a null answer read as a value"
  doAssert "no answer within" notin m, label & ": the null endpoint timed out instead: " & m
doAssert probeRpc(nulls).detail == "no result"
nullRaises("safeNonce", raisesOn(safeNonce(nulls, safeAddr)))
nullRaises("safe getBalance", raisesOn(getBalance(nulls, safeAddr)))
nullRaises("ethCall", raisesOn(ethCall(nulls, safeAddr, @[0x01'u8])))
nullRaises("submitExecTransaction", raisesOn(submitExecTransaction(nulls, safeAddr, safeAddr, @[0x01'u8])))
doAssert not getOwners(nulls, safeAddr).known
doAssert watchReceiptStatus(nulls, txh) == -1, "a null receipt is the chain's answer: not yet mined"
nullRaises("rpcBalance", raisesOn(rpcBalance(nulls, zero, "latest")))
nullRaises("rpcChainId", raisesOn(rpcChainId(nulls)))
nullRaises("rpcGasPrice", raisesOn(rpcGasPrice(nulls)))
nullRaises("rpcNonce", raisesOn(rpcNonce(nulls, zero)))
doAssert rpcReceiptStatus(nulls, txh) == -1, "a null receipt is the chain's answer: not yet mined"
doAssert not rpcTransferOf(nulls, txh).found, "a null transaction is the chain's answer: not known"
let lezNulls = newLezRpc(nulls)
nullRaises("lez lastBlockId", raisesOn(lezNulls.lastBlockId()))
nullRaises("lez sendTransaction", raisesOn(lezNulls.sendTransaction(@[0x01'u8])))
nullRaises("lez programId", raisesOn(lezNulls.programId("token")))
nullRaises("lez getAccount", raisesOn(lezNulls.getAccount(newSeq[byte](32))))
doAssert not lezNulls.getTransaction("ab").known, "a null transaction is the chain's answer: not known"
echo "5. a null read raises (nonce, balance, call, tx hash, height); null receipt / tx stay the chain's answer OK"

# ── 6. the Bitcoin node (wallet/btc_adapter.nim, exo-496) ──────────────────────
let regtestAddr = "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
let rawPayload = PreparedTx(payload: $(%*{"rawtx": "00"}))
let btcSilent = newBitcoindAdapterFromUrl("regtest", silent)
timed("btc getblockcount", ReadMs, proc(): string = raisesOn(btcSilent.call("getblockcount")))
timed("btc getwalletinfo /wallet/w", ReadMs, proc(): string =
  raisesOn(btcSilent.call("getwalletinfo", wallet = "w")))
timed("btc probeBitcoind", ProbeMs, proc(): string =
  let p = probeBitcoind(silent)
  doAssert not p.ok
  p.detail)
timed("btc estimateFee", ReadMs, proc(): string =
  raisesOn(btcSilent.estimateFee(Account(), "", Amount())))
timed("btc finality", ReadMs, proc(): string =
  raisesOn(btcSilent.finality(TxRef(id: repeat("ab", 32)))))
timed("btc utxosOf (scantxoutset)", ScanMs, proc(): string = raisesOn(btcSilent.utxosOf(regtestAddr)))
timed("btc spendableUtxosOf", ScanMs, proc(): string = raisesOn(btcSilent.spendableUtxosOf(regtestAddr)))
timed("btc submit (sendrawtransaction)", SendMs, proc(): string = raisesOn(btcSilent.submit(rawPayload, nil)))
# the connect is bounded too: an address that drops SYNs fails within a read's budget,
# the scan's and the broadcast's longer budgets included (they are the node's work, not
# the connect's)
let btcDropping = newBitcoindAdapterFromUrl("regtest", dropping)
timed("btc getblockcount, SYNs dropped", ReadMs, proc(): string =
  raisesOn(btcDropping.call("getblockcount")))
timed("btc utxosOf, SYNs dropped", ReadMs, proc(): string =
  raisesOn(btcDropping.utxosOf(regtestAddr)), named = "unreachable")
timed("btc submit, SYNs dropped", ReadMs, proc(): string =
  raisesOn(btcDropping.submit(rawPayload, nil)), named = "unreachable")
timed("probeRpc, SYNs dropped", ProbeMs, proc(): string =
  let p = probeRpc(dropping)
  doAssert not p.ok
  p.detail)
echo "6. every Bitcoin node call fails within its budget on a silent endpoint; a connect that never completes within a read's OK"

# ── 7. the Bitcoin node's answers: the error is in the body, whatever the status ─
block:
  let node = newBitcoindAdapterFromUrl("regtest", coreNode.replace("://", "://muster:s3cret@"))
  # bitcoind answers an RPC error with HTTP 500 and the error object in the body: the
  # node's message reaches the caller, as before this seam
  let m = raisesOn(node.submit(rawPayload, nil))
  doAssert m == "bitcoind sendrawtransaction: min relay fee not met, 110 < 141 (-26)", m
  let nf = raisesOn(node.call("nosuchmethod"))
  doAssert nf == "bitcoind nosuchmethod: Method not found (-32601)", nf
  # a failure status with no error object is a failure, never a null result
  let u = raisesOn(node.call("getblockcount"))
  doAssert u.startsWith("bitcoind getblockcount: HTTP 503 Service Unavailable"), u
  # credentials travel as Basic auth, and a wallet call reaches /wallet/<name>
  doAssert node.call("getwalletinfo", wallet = "carol"){"path"}.getStr() == "/wallet/carol"
  doAssert node.call("getwalletinfo"){"path"}.getStr() == "/"
  # a wrong password: bitcoind's 401 has no body; the status names it, the URL's
  # credentials appear nowhere
  let wrong = coreNode.replace("://", "://muster:wrong@")
  let a = raisesOn(newBitcoindAdapterFromUrl("regtest", wrong).call("getblockcount"))
  doAssert a == "bitcoind getblockcount: HTTP 401 Unauthorized", a
  let p = probeBitcoind(wrong)
  doAssert not p.ok and "401" in p.detail and "wrong" notin p.detail, p.detail
  doAssert redactUrl(wrong) == coreNode.replace("://", "://***@")      # the user too (wallet/redact.nim, exo-14f.2)
  for msg in [m, nf, u, a, p.detail]: doAssert "s3cret" notin msg and "wrong" notin msg, msg
echo "7. bitcoind's HTTP 500 carries the node's message; a 401 names the status, never the credentials OK"

# ── 8. the budgets restore ────────────────────────────────────────────────────
setRpcBudgets()
doAssert readBudget() == ReadBudget and sendBudget() == SendBudget and probeBudget() == ProbeBudget and
         scanBudget() == ScanBudget
echo "8. defaults: read " & $ReadBudget & ", send " & $SendBudget & ", probe " & $ProbeBudget &
     ", scan " & $ScanBudget & " OK"

echo "rpc_budget_test: all OK (" & $checked & " calls held to their budget; worst overrun " &
     $worstOverMs & " ms)"
quit(0)
