## A Bitcoin node the probes can run without a chain (derived-exo-a90.20 s7, s8). The grader
## runs probes with no network and no bitcoind, and the Bitcoin seam's own code — coin
## selection (spendableUtxosOf), sending, partLanded, partGone, the creditor's checkReceived
## — speaks JSON-RPC over HTTP to "your node". So a probe starts this: a child process (the
## probe binary itself, re-invoked as `<probe> fake-bitcoind <network> <port>`) holding a
## UTXO set, a mempool and a chain height, answering the calls the seam makes, plus a few
## control calls for the probe:
##   fake_fund [address, sats]      a confirmed coin paying `address`
##   fake_mine [n]                  confirm the mempool, and n blocks on top
##   fake_drop [txid]               the payment leaves the mempool unmined
##   fake_conflict [txid, address]  the payment's first coin is spent to `address` by another
##                                  transaction, which is mined — it can never land now
## Not a probe itself (no `probe_` prefix). The seam's code runs unmodified against it.

import std/[json, net, os, osproc, strutils, tables, sets]
import ../../src/bitcoin/[tx, bech32, network]
import ../../src/hashing/sha256

type
  Coin = object
    value: uint64
    spk: string          ## hex
  Mined = object
    height: int
    info: JsonNode       ## vin / vout as getrawtransaction shows them

var utxo: Table[string, Coin]            ## "txid:vout" -> a confirmed, unspent coin
var mempool: OrderedTable[string, BtcTx]
var mined: Table[string, Mined]
var height = 100
var synthetic = 0
var hrp = "bcrt"
var genesis = ""

proc btcOf(sats: uint64): float = float(sats) / 1e8

proc voutJson(outs: seq[TxOut]): JsonNode =
  result = newJArray()
  for n, o in outs:
    result.add %*{"value": btcOf(o.value), "n": n, "scriptPubKey": {"hex": toHex(o.scriptPubKey)}}

proc vinJson(t: BtcTx): JsonNode =
  result = newJArray()
  for i in t.inputs:
    var r = i.prevout.txid
    for k in 0 ..< 16: swap(r[k], r[31 - k])
    result.add %*{"txid": toHex(r), "vout": int(i.prevout.vout)}

proc inputKey(i: TxIn): string =
  var r = i.prevout.txid
  for k in 0 ..< 16: swap(r[k], r[31 - k])
  toHex(r) & ":" & $i.prevout.vout

proc spentInMempool(): HashSet[string] =
  for _, t in mempool:
    for i in t.inputs: result.incl inputKey(i)

proc confirm(txid: string, t: BtcTx) =
  inc height
  for i in t.inputs: utxo.del inputKey(i)
  for n, o in t.outputs: utxo[txid & ":" & $n] = Coin(value: o.value, spk: toHex(o.scriptPubKey))
  mined[txid] = Mined(height: height, info: %*{"vin": vinJson(t), "vout": voutJson(t.outputs),
                                                "hex": toHex(t.serialize())})

proc syntheticId(): string =
  inc synthetic
  var b: seq[byte]
  for ch in "fake-bitcoind-" & $synthetic: b.add byte(ch)
  toHex(sha256(b))

proc rpcError(code: int, msg: string): JsonNode = %*{"result": nil, "error": {"code": code, "message": msg}}
proc ok(r: JsonNode): JsonNode = %*{"result": r, "error": nil}

proc handle(req: JsonNode): JsonNode =
  let m = req{"method"}.getStr()
  let p = req{"params"}
  case m
  of "getblockhash": ok(%genesis)
  of "getblockcount": ok(%height)
  of "getindexinfo": ok(%*{"txindex": {"synced": true, "best_block_height": height}})
  of "estimatesmartfee": ok(%*{"feerate": 0.00002, "blocks": 6})
  of "getnetworkinfo": ok(%*{"relayfee": 0.00001})
  of "scantxoutset":
    let d = p[1][0].getStr()                               # "addr(<address>)"
    let spk = toHex(scriptPubKeyOfAddress(hrp, d[5 ..< d.len - 1]))
    var us = newJArray()
    var total = 0'u64
    for k, c in utxo:
      if c.spk == spk:
        let c2 = k.rfind(':')
        us.add %*{"txid": k[0 ..< c2], "vout": parseInt(k[c2 + 1 .. ^1]), "scriptPubKey": c.spk,
                  "amount": btcOf(c.value)}
        total += c.value
    ok(%*{"success": true, "unspents": us, "total_amount": btcOf(total)})
  of "gettxout":
    let key = p[0].getStr() & ":" & $p[1].getInt()
    if key notin utxo or (p.len > 2 and p[2].getBool() and key in spentInMempool()): ok(newJNull())
    else: ok(%*{"value": btcOf(utxo[key].value), "scriptPubKey": {"hex": utxo[key].spk}})
  of "sendrawtransaction":
    var t: BtcTx
    try: t = parseTx(hexToBytes(p[0].getStr()))
    except CatchableError as e: return rpcError(-22, "TX decode failed: " & e.msg)
    let id = t.txidHex()
    if id in mempool or id in mined: return rpcError(-27, "transaction already in block chain or mempool")
    let taken = spentInMempool()
    for i in t.inputs:
      let k = inputKey(i)
      if k notin utxo: return rpcError(-25, "bad-txns-inputs-missingorspent")
      if k in taken: return rpcError(-26, "txn-mempool-conflict")
    mempool[id] = t
    ok(%id)
  of "getrawtransaction":
    let id = p[0].getStr()
    if id in mempool:
      let t = mempool[id]
      return ok(%*{"txid": id, "confirmations": 0, "vin": vinJson(t), "vout": voutJson(t.outputs),
                   "hex": toHex(t.serialize())})
    if id in mined:
      let x = mined[id]
      var info = %*{"txid": id, "confirmations": height - x.height + 1, "vin": x.info["vin"], "vout": x.info["vout"]}
      if x.info.hasKey("hex"): info["hex"] = x.info["hex"]
      return ok(info)
    rpcError(-5, "No such mempool or blockchain transaction")
  of "fake_fund":
    let id = syntheticId()
    inc height
    let spk = toHex(scriptPubKeyOfAddress(hrp, p[0].getStr()))
    utxo[id & ":0"] = Coin(value: uint64(p[1].getBiggestInt()), spk: spk)
    mined[id] = Mined(height: height, info: %*{"vin": [], "vout": [{"value": btcOf(uint64(p[1].getBiggestInt())),
                                                                       "n": 0, "scriptPubKey": {"hex": spk}}]})
    ok(%id)
  of "fake_mine":
    var ids: seq[string]
    for id, _ in mempool: ids.add id
    for id in ids:
      confirm(id, mempool[id])
      mempool.del id
    height += max(0, p[0].getInt() - 1)
    ok(%height)
  of "fake_drop":
    mempool.del p[0].getStr()
    ok(newJNull())
  of "fake_conflict":
    let id = p[0].getStr()
    if id notin mempool: return rpcError(-5, "not in the mempool")
    let t = mempool[id]
    mempool.del id
    let k = inputKey(t.inputs[0])
    let spk = toHex(scriptPubKeyOfAddress(hrp, p[1].getStr()))
    let other = syntheticId()
    inc height
    let value = utxo[k].value
    utxo.del k
    utxo[other & ":0"] = Coin(value: value, spk: spk)
    mined[other] = Mined(height: height, info: %*{"vin": [{"txid": k[0 ..< k.rfind(':')],
                                                            "vout": parseInt(k[k.rfind(':') + 1 .. ^1])}],
                                                   "vout": [{"value": btcOf(value), "n": 0, "scriptPubKey": {"hex": spk}}]})
    ok(%other)
  else: rpcError(-32601, "Method not found: " & m)

proc serve(net: BtcNetwork, port: int) =
  hrp = net.hrp
  genesis = net.caip2[7 .. ^1] & repeat('0', 32)
  let sock = newSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(port), "127.0.0.1")
  sock.listen()
  while true:
    var client: Socket
    sock.accept(client)
    var length = 0
    while true:
      let line = client.recvLine()
      if line == "\r\L" or line.len == 0: break
      if line.toLowerAscii().startsWith("content-length:"): length = parseInt(line.split(':')[1].strip())
    let body = (if length > 0: client.recv(length) else: "")
    var resp: JsonNode
    try: resp = handle(parseJson(body))
    except CatchableError as e: resp = rpcError(-1, e.msg)
    let payload = $resp
    client.send("HTTP/1.1 200 OK\r\LContent-Type: application/json\r\LContent-Length: " & $payload.len &
                "\r\LConnection: close\r\L\r\L" & payload)
    client.close()

proc fakeBitcoindMain*() =
  ## When the probe binary is invoked as the fake node, serve for ever; otherwise return.
  if paramCount() >= 3 and paramStr(1) == "fake-bitcoind":
    serve(networkByCaip2(paramStr(2)), parseInt(paramStr(3)))
    quit(0)

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

type FakeNode* = object
  process*: Process
  url*: string

proc startFakeNode*(chain: string): FakeNode =
  ## A fresh fake node for `chain` (a CAIP-2 Bitcoin id), answering once it listens.
  let port = freePort()
  result.process = startProcess(getAppFilename(), args = ["fake-bitcoind", chain, $port], options = {})
  result.url = "http://127.0.0.1:" & $port
  for _ in 0 ..< 200:
    try:
      let s = newSocket()
      s.connect("127.0.0.1", Port(port))
      s.close()
      return
    except CatchableError: sleep(20)
  raise newException(IOError, "the fake node did not start")

proc stop*(n: FakeNode) =
  n.process.terminate()
  discard n.process.waitForExit()
  n.process.close()
