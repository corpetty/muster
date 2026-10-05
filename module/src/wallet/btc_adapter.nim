## BitcoindAdapter — Bitcoin behind the ChainAdapter seam (exo-a50.2.5, Phase B).
##
## The user's own Bitcoin Core node over JSON-RPC (basic auth): untrusted,
## user-configured infrastructure (invariant 8), like an EVM RPC. What the multisig
## families need from it is small:
##
##   utxosOf(address)  — scantxoutset: the account's coins, read from the node's UTXO
##                       set (no wallet, no index) — the external read a spend's inputs
##                       cite (invariant 10)
##   submit(tx)        — sendrawtransaction of a finalized transaction the Bitcoin
##                       settlement assembled; the adapter holds no key and signs nothing
##   finality(txRef)   — getrawtransaction: pending until mined, final at the network's
##                       confirmation depth (1 on regtest, 6 elsewhere) — observed, never
##                       asserted (R-8). A confirmed transaction is found only with
##                       -txindex (infra/bitcoind/regtest.sh sets it); without it the
##                       read raises rather than guess.
##
## The multisig accounts themselves live in rooms (disclosed by members), so the
## adapter derives no account from the module identity, and a wallet-level transfer is
## not how a multisig spends — both say so rather than pretend. Every failure raises
## WalletError; a failed read is never a zero balance. RPC amounts are BTC decimals;
## they become satoshis by rounding ×1e8, exact for every amount Bitcoin can hold
## (< 2^53 sat), and nothing on a signing path ever sees a float (invariant 5).
##
## Every call runs on the module dispatch thread under a budget (wallet/rpc_budget.nim,
## exo-14f, exo-496): a read readBudget(), the broadcast sendBudget(), the scan
## scanBudget(), the chain probe probeBudget(). A node that does not answer in time is an
## error, never a wait for the kernel's TCP timeout.

import std/[json, base64, strutils, math, uri]
import chronos
import chronos/apps/http/httpclient
import stew/byteutils
import ./types
import ./adapter
import ./rpc_budget
import ../crypto/keystore
import ../bitcoin/[tx, network]

type
  BitcoindAdapter* = ref object of ChainAdapter
    network*: BtcNetwork
    url*: string
    user, pass: string
    finalDepth*: int      ## confirmations that make a transaction final here

proc newBitcoindAdapter*(networkName, url, user, pass: string): BitcoindAdapter =
  let net = networkByName(networkName)
  BitcoindAdapter(network: net, url: url.strip(chars = {'/'}, leading = false), user: user, pass: pass,
                  finalDepth: (if net.name == "regtest": 1 else: 6))

proc splitCredentials*(url: string): tuple[url, user, pass: string] =
  ## A node URL may carry its RPC credentials ("http://user:pass@host:port"): split them
  ## out, so they travel as a Basic auth header and are never echoed back.
  var u = parseUri(url)
  result.user = decodeUrl(u.username)
  result.pass = decodeUrl(u.password)
  u.username = ""
  u.password = ""
  result.url = ($u).strip(chars = {'/'}, leading = false)

proc redactUserinfo*(url: string): string =
  ## the URL as it may be shown: credentials never are
  let (bare, user, _) = splitCredentials(url)
  if user.len == 0: bare else: bare.replace("://", "://" & user & ":***@")

proc newBitcoindAdapterFromUrl*(networkName, url: string): BitcoindAdapter =
  let (bare, user, pass) = splitCredentials(url)
  newBitcoindAdapter(networkName, bare, user, pass)

proc nativeAsset(a: BitcoindAdapter): AssetId =
  AssetId(chain: a.network.caip2, symbol: "BTC", kind: akNative, decimals: 8)

type NodeAnswer = tuple[status: int, reason, body: string]

proc exchange(address: HttpAddress, headers: seq[HttpHeaderTuple], body: string,
              connectBy, headersBy: Duration): Future[NodeAnswer] {.
              async: (raises: [CancelledError, HttpError]).} =
  ## One POST and its whole answer, whatever the status: bitcoind answers an RPC error
  ## with HTTP 500 (404 for an unknown method) and the error object in the body. Not
  ## nim-json-rpc's client, which raises on a non-2xx status before it reads the body.
  let session = HttpSessionRef.new(connectTimeout = connectBy, headersTimeout = headersBy)
  var req: HttpClientRequestRef
  var resp: HttpClientResponseRef
  try:
    req = HttpClientRequestRef.new(session, address, MethodPost, headers = headers,
                                   body = body.toBytes())
    resp = await req.send()
    let bytes = await resp.getBodyBytes()
    (resp.status, resp.reason, string.fromBytes(bytes))
  finally:
    if resp != nil: await resp.closeWait()
    if req != nil: await req.closeWait()
    await session.closeWait()

proc httpFailure(meth: string, ans: NodeAnswer): ref WalletError =
  ## an answer that is not JSON-RPC, or a failure status with no error object
  var m = "bitcoind " & meth & ": HTTP " & $ans.status
  if ans.reason.len > 0: m.add " " & ans.reason
  if ans.body.len > 0: m.add " " & ans.body
  newException(WalletError, m)

proc call*(a: BitcoindAdapter, meth: string, params: JsonNode = newJArray(), wallet = "",
           budget = readBudget()): JsonNode =
  ## One JSON-RPC call; `wallet` routes it to /wallet/<name>. `budget` is one deadline
  ## over connect, request, headers and body; the connect alone gets at most a read's
  ## budget, so a node that cannot be reached fails as fast as a read whatever the call,
  ## and only the node's own work (a scan, a broadcast's validation) is given longer.
  ## A transport failure, no answer within the budget, or an RPC error raises
  ## WalletError naming the method and the node's message — never the URL, which may
  ## carry credentials.
  let body = $(%*{"jsonrpc": "1.0", "id": "muster", "method": meth, "params": params})
  let headers: seq[HttpHeaderTuple] = @[(key: "Content-Type", value: "application/json"),
    (key: "Authorization", value: "Basic " & encode(a.user & ":" & a.pass))]
  let address = getHttpAddress(if wallet.len > 0: a.url & "/wallet/" & wallet else: a.url).valueOr:
    raise newException(WalletError, "bitcoind " & meth & ": not a node URL (" & $error & ")")
  # chronos's own timers: the connect's as above; the headers' past the budget, so its
  # 120 s default never ends a scan the budget allows
  let connectBy = (if budget > readBudget(): readBudget() else: budget + 1.seconds)
  var ans: NodeAnswer
  try: ans = bounded(exchange(address, headers, body, connectBy, budget + 1.seconds), budget)
  except RpcTimeoutError:
    raise newException(WalletError, "bitcoind " & meth & ": no answer within " & $budget)
  except CatchableError as e:
    raise newException(WalletError, "bitcoind " & meth & ": unreachable: " & e.msg)
  var j: JsonNode
  try: j = parseJson(ans.body)
  except CatchableError: raise httpFailure(meth, ans)
  let err = j{"error"}
  if err != nil and err.kind != JNull:
    raise newException(WalletError, "bitcoind " & meth & ": " & err{"message"}.getStr($err) &
                                     " (" & $err{"code"}.getInt() & ")")
  if ans.status div 100 != 2: raise httpFailure(meth, ans)   # a failure with no error object is still one
  j{"result"}

proc toSat(btc: JsonNode): uint64 =
  if btc == nil or btc.kind notin {JFloat, JInt}: raise newException(WalletError, "not an amount: " & $btc)
  let f = (if btc.kind == JInt: float(btc.getInt()) else: btc.getFloat())
  if f < 0: raise newException(WalletError, "a negative amount: " & $btc)
  uint64(round(f * 1e8))

proc utxosOf*(a: BitcoindAdapter, address: string): seq[BtcUtxo] =
  ## The address's confirmed coins, from the node's UTXO set (scantxoutset).
  if hrpOfAddress(address) != a.network.hrp:
    raise newException(WalletError, address & " is not a " & a.network.name & " address")
  # under scanBudget() (rpc_budget.nim says why). Past it the node's scan runs on and a
  # retry meanwhile is refused by the node ("Scan already in progress"); muster never
  # sends "abort", which stops whatever scan the node is running, another client's too
  let r = a.call("scantxoutset", %*["start", ["addr(" & address & ")"]], budget = scanBudget())
  if r == nil or r.kind != JObject or not r{"success"}.getBool(false):
    raise newException(WalletError, "scantxoutset did not complete for " & address)
  for u in r{"unspents"}:
    result.add BtcUtxo(txid: u{"txid"}.getStr(), vout: uint32(u{"vout"}.getInt()),
                       value: toSat(u{"amount"}), scriptPubKey: u{"scriptPubKey"}.getStr())

proc spendableUtxosOf*(a: BitcoindAdapter, address: string): seq[BtcUtxo] =
  ## The address's confirmed coins that no transaction in the node's mempool already spends
  ## (gettxout with the mempool included answers null for those). scantxoutset reads the
  ## chain alone, so a payment sent a moment ago still shows its coins unspent there; a
  ## second payment built from them would conflict with the first — refused, or worse,
  ## replacing it (Core's full RBF) — exo-a90.18.
  for u in a.utxosOf(address):
    let r = a.call("gettxout", %*[u.txid, int(u.vout), true])
    if r != nil and r.kind == JObject: result.add u

method describe*(a: BitcoindAdapter): ChainDescriptor =
  ChainDescriptor(chain: a.network.caip2, displayName: "Bitcoin (" & a.network.name & ")",
                  nativeAsset: a.nativeAsset(), accountForms: @[afPublic],
                  finality: (if a.finalDepth <= 1: finImmediate else: finProbabilistic))

method accounts*(a: BitcoindAdapter, ks: Keystore): seq[Account] =
  ## None from the module identity: a multisig account is disclosed in a room.
  @[]

method assets*(a: BitcoindAdapter): seq[AssetId] = @[a.nativeAsset()]

method balance*(a: BitcoindAdapter, account: Account, asset: AssetId): Amount =
  if asset.chain != a.network.caip2 or asset.kind != akNative:
    raise newException(WalletError, "bitcoind holds only " & a.network.caip2 & "'s native asset")
  var total: uint64
  for u in a.utxosOf(account.id): total += u.value
  Amount(asset: a.nativeAsset(), raw: $total)

method estimateFee*(a: BitcoindAdapter, frm: Account, to: string, amt: Amount): FeeEstimate =
  ## The node's fee rate for confirmation within 6 blocks; a node without the data (a
  ## fresh regtest) raises — the rate is chosen, never invented.
  let r = a.call("estimatesmartfee", %*[6])
  if r == nil or r{"feerate"} == nil:
    raise newException(WalletError, "the node has no fee estimate: " & $r{"errors"})
  let satPerVb = max(1'u64, toSat(r{"feerate"}) div 1000)
  FeeEstimate(fee: Amount(asset: a.nativeAsset(), raw: $satPerVb), note: $satPerVb & " sat/vB (estimatesmartfee, 6 blocks)")

method prepareTransfer*(a: BitcoindAdapter, frm: Account, to: string, amt: Amount): PreparedTx =
  raise newException(WalletError, "a multisig spend is proposed in a room (btc-spend) and settled " &
                                  "by its Bitcoin settlement — the wallet does not prepare one")

method submit*(a: BitcoindAdapter, tx: PreparedTx, ks: Keystore): TxRef =
  ## Broadcast a finalized transaction ({"rawtx": hex}); the node's txid must be the one
  ## the settlement computed, or the broadcast is not the transaction that was assembled.
  var raw, want: string
  try:
    let p = parseJson(tx.payload)
    raw = p{"rawtx"}.getStr()
    want = p{"txid"}.getStr()
  except CatchableError: raise newException(WalletError, "not a Bitcoin payload")
  if raw.len == 0: raise newException(WalletError, "no raw transaction to broadcast")
  let got = a.call("sendrawtransaction", %*[raw], budget = sendBudget()).getStr()
  if want.len > 0 and got != want:
    raise newException(WalletError, "the node accepted " & got & ", not the assembled " & want)
  TxRef(chain: a.network.caip2, id: got)

method finality*(a: BitcoindAdapter, txRef: TxRef): Finality =
  let r = a.call("getrawtransaction", %*[txRef.id, true])
  let conf = r{"confirmations"}.getInt(0)
  if conf >= a.finalDepth: Finality(status: fsFinal, detail: $conf & " confirmation(s)")
  else: Finality(status: fsPending, detail: (if conf == 0: "in the mempool" else: $conf & " confirmation(s)"))

proc probeBitcoind*(url: string): tuple[ok: bool, chain: string, detail: string] {.gcsafe.} =
  ## Which chain the node at `url` serves, as CAIP-2 (bip122:<first 32 hex of the
  ## genesis block hash>) — asked of the node, never assumed from a setting. A liveness
  ## probe, as safe_rpc's probeRpc: within probeBudget(), reachable quickly or down.
  try:
    {.cast(gcsafe).}:
      let (bare, user, pass) = splitCredentials(url)
      let a = BitcoindAdapter(url: bare, user: user, pass: pass, finalDepth: 1)
      let genesis = a.call("getblockhash", %*[0], budget = probeBudget()).getStr()
      if genesis.len != 64: return (false, "", "not a block hash: " & genesis)
      let chain = "bip122:" & genesis[0 ..< 32]
      var name = chain
      try: name = networkByCaip2(chain).name
      except CatchableError: discard
      (true, chain, "the node serves " & name & " (" & chain & ")")
  except CatchableError as e:
    (false, "", e.msg)
