## A configured RPC URL never reaches text whole (invariant 8, exo-14f.2).
##
## A hosted RPC endpoint often carries its credentials in the URL: userinfo
## (http://user:pass@host) or a key in the path (https://mainnet.infura.io/v3/<key>). The
## module shows an endpoint only as wallet/redact.nim's redactUrl shows it — scheme, host
## and port — in every text it hands out: the split composer's "your RPC did not answer"
## (parts_evm.rpcChainCaip2), the room's RPC connectivity row (readiness.rpcConnectivityRow,
## which musterConnectivity also writes to the MUSTER-LP debug log), and the readiness
## card's infra details. Each is driven here with a URL carrying both, against an endpoint
## that refuses and one that answers, and none of the URL's secrets may appear.

import std/[json, net, nativesockets, strutils]
import ../src/wallet/redact
import ../src/wallet/btc_adapter
import ../src/drivers/safe_rpc
import ../src/coordination/readiness
import ../src/coordination/parts_evm

const
  User = "rpcuser7"
  Pass = "s3cr3tPass"
  Key = "k3yInThePath0123456789"
  Secrets = [User, Pass, Key, "/v3/"]

proc credentialed(base: string): string =
  ## `base` ("http://127.0.0.1:<port>") with userinfo and a key in the path
  base.replace("://", "://" & User & ":" & Pass & "@") & "/v3/" & Key

proc clean(text, url: string) =
  doAssert url notin text, text
  for s in Secrets: doAssert s notin text, "\"" & s & "\" in: " & text

# ── an endpoint that answers every JSON-RPC call with chain 1 ─────────────────
proc answerChain1(fd: SocketHandle) {.thread.} =
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
      let body = $(%*{"jsonrpc": "2.0", "id": id, "result": "0x1"})
      c.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " & $body.len &
             "\r\nConnection: close\r\n\r\n" & body)
    except CatchableError: discard
    c.close()

let listener = newSocket()
listener.setSockOpt(OptReuseAddr, true)
listener.bindAddr(Port(0), "127.0.0.1")
listener.listen()
var server: Thread[SocketHandle]
createThread(server, answerChain1, listener.getFd())
let answering = credentialed("http://127.0.0.1:" & $int(listener.getLocalAddr()[1]))
let refusing = credentialed("http://127.0.0.1:1")      # nothing listens on port 1

# ── 1. redactUrl: scheme, host and port; "***" for userinfo and for any path ──
block:
  doAssert redactUrl(answering) == "http://***@127.0.0.1:" & $int(listener.getLocalAddr()[1]) & "/***"
  doAssert redactUrl("https://mainnet.infura.io/v3/" & Key) == "https://mainnet.infura.io/***"
  doAssert redactUrl("http://" & User & ":" & Pass & "@node:8332") == "http://***@node:8332"
  doAssert redactUrl("http://" & Key & "@node/") == "http://***@node"           # a key as the user
  doAssert redactUrl("http://:" & Pass & "@node") == "http://***@node"
  doAssert redactUrl("https://node?apikey=" & Key) == "https://node/***"
  doAssert redactUrl("https://node#" & Key) == "https://node/***"
  doAssert redactUrl("http://127.0.0.1:8545") == "http://127.0.0.1:8545"       # nothing to hide
  doAssert redactUrl("http://127.0.0.1:8545/") == "http://127.0.0.1:8545"
  doAssert redactUrl("https://testnet.lez.logos.co") == "https://testnet.lez.logos.co"
  doAssert redactUrl("http://[::1]:8545/v3/" & Key) == "http://[::1]:8545/***"
  doAssert redactUrl("") == "" and redactUrl("  ") == ""                       # none: nothing shown
  doAssert redactUrl("localhost:8545") == "***"                                # no host: hidden whole
  doAssert redactUrl("not a url " & Key) == "***"
  doAssert redactUrl("http://node:85" & Key) == "***"                          # not a port
  doAssert redactUrl("http://u:p@" & Pass & "@node/x") == "http://***@node/***"
  echo "1. redactUrl keeps scheme, host and port; userinfo and path are ***; no host, all *** OK"

# ── 2. the split composer: "your RPC did not answer" ──────────────────────────
block:
  let r = rpcChainCaip2(refusing)
  doAssert not r.ok and r.detail.startsWith("your RPC (" & redactUrl(refusing) & ") did not answer: "), r.detail
  clean(r.detail, refusing)
  let a = rpcChainCaip2(answering)          # the call still dials the whole URL
  doAssert a.ok and a.chain == "eip155:1", $a
  clean($a, answering)
  echo "2. the split composer's RPC error names the endpoint redacted, never its secrets OK"

# ── 3. the room's RPC connectivity row (the UI, and the MUSTER-LP debug log) ──
block:
  let down = rpcConnectivityRow(refusing, @[31337])
  doAssert down["level"].getStr() == "down" and down["endpoint"].getStr() == redactUrl(refusing), $down
  clean("MUSTER-LP connectivity " & $(%*{"rows": [down]}), refusing)
  let ok = rpcConnectivityRow(answering, @[1])
  doAssert ok["level"].getStr() == "ok" and ok["detail"].getStr() == "chain 1", $ok
  clean($ok, answering)
  let warn = rpcConnectivityRow(answering, @[31337])
  doAssert warn["level"].getStr() == "warn" and "needs chain 31337" in warn["detail"].getStr(), $warn
  clean($warn, answering)
  let none = rpcConnectivityRow("", @[31337])
  doAssert none["level"].getStr() == "down" and none["endpoint"].getStr() == "", $none   # the UI shows none
  echo "3. the connectivity row shows the endpoint redacted, down, ok and warn alike OK"

# ── 4. the readiness card's infra and environment details ─────────────────────
block:
  let p = probeFromFacts(HostFacts(rpcUrl: refusing, lezRpcUrl: refusing, btcRpcUrl: refusing))
  for name in ["rpc", "lez-rpc", "bitcoind-rpc"]:
    let g = p.infraConfigured(name)
    doAssert g.status == rdMet and redactUrl(refusing) in g.detail, name & ": " & g.detail
    clean(g.detail, refusing)
  for chain in ["eip155:1", "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"]:
    let g = p.environmentReachable(chain)
    doAssert g.status == rdMissing, chain & ": " & g.detail
    clean(g.detail, refusing)
  clean(probeRpc(refusing).detail, refusing)
  clean(probeBitcoind(refusing).detail, refusing)
  echo "4. the readiness details name each endpoint redacted; a failed probe names none OK"

echo "rpc_url_redaction_test: all OK"
quit(0)   # the endpoint's thread blocks in accept; end the process with it
