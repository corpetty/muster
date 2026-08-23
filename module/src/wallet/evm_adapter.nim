## The EVM ChainAdapter — native ETH + ERC-20 tokens over the user's JSON-RPC
## endpoint (invariant 8: untrusted, user-configured; no indexer, no third-party
## API). Balance reads are `verified-locally` facts the client performs itself
## (F-10). This is the same chain the Safe driver settles on; the wallet is the
## account-level view of it, distinct from the coordinated intent path.
##
## The pure pieces — ERC-20 calldata assembly, hex<->decimal balance parsing,
## account derivation — are exported and unit-tested without a node; the RPC
## methods are thin wrappers over them.

import std/[httpclient, json, tables, strutils]
import ./types
import ./adapter
import ../crypto/secp256k1
import ../crypto/keystore

# ── pure helpers (unit-tested; no node) ────────────────────────────────────────

proc addrHex*(a: Address): string =
  const hexd = "0123456789abcdef"
  result = "0x"
  for b in a: (result.add hexd[int(b shr 4)]; result.add hexd[int(b and 0xF)])

proc pad32(hexNoPrefix: string): string =
  ## Left-pad a hex string to a 32-byte (64-hex-char) EVM word.
  if hexNoPrefix.len > 64: raise newException(WalletError, "word too wide")
  '0'.repeat(64 - hexNoPrefix.len) & hexNoPrefix

proc erc20BalanceOfData*(owner: Address): string =
  ## balanceOf(address) — selector 70a08231.
  "0x70a08231" & pad32(addrHex(owner)[2 .. ^1])

proc erc20TransferData*(to: Address, rawAmount: string): string =
  ## transfer(address,uint256) — selector a9059cbb.
  "0xa9059cbb" & pad32(addrHex(to)[2 .. ^1]) & pad32(decToHex(rawAmount))

# ── the adapter ────────────────────────────────────────────────────────────────

type
  EvmAdapter* = ref object of ChainAdapter
    chainId: string
    rpcUrl: string
    native: AssetId
    tokens: seq[AssetId]         ## reference = the token contract address (0x…)
    fromUnlocked: bool           ## anvil unlocks accounts → eth_sendTransaction needs no client-side signing

proc newEvmAdapter*(chainId, rpcUrl: string, tokens: seq[AssetId] = @[],
                    fromUnlocked = true): EvmAdapter =
  let native = AssetId(chain: chainId, symbol: "ETH", kind: akNative, decimals: 18)
  EvmAdapter(chainId: chainId, rpcUrl: rpcUrl, native: native, tokens: tokens,
             fromUnlocked: fromUnlocked)

proc rpc(a: EvmAdapter, meth: string, params: JsonNode): JsonNode =
  ## One JSON-RPC call to the user's endpoint. Any transport error, or a JSON-RPC
  ## `error` object, becomes a raise — a failed call never returns a value a caller
  ## could read as success.
  let client = newHttpClient()
  defer: client.close()
  let body = %*{"jsonrpc": "2.0", "id": 1, "method": meth, "params": params}
  var resp: string
  try:
    resp = client.request(a.rpcUrl, httpMethod = HttpPost, body = $body,
                          headers = newHttpHeaders({"Content-Type": "application/json"})).body
  except CatchableError as e:
    raise newException(WalletError, "RPC transport error: " & e.msg)
  let j = parseJson(resp)
  if j.hasKey("error") and j["error"].kind != JNull:
    raise newException(WalletError, "RPC error: " & $j["error"])
  if not j.hasKey("result") or j["result"].kind == JNull:
    raise newException(WalletError, "RPC returned no result for " & meth)
  j["result"]

proc toAddress(id: string): Address =
  var h = id
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  if h.len != 40: raise newException(WalletError, "not a 20-byte address: " & id)
  for i in 0 ..< 20:
    let hi = h[2*i]; let lo = h[2*i+1]
    proc nib(c: char): int =
      if c >= '0' and c <= '9': ord(c) - ord('0')
      elif c >= 'a' and c <= 'f': 10 + ord(c) - ord('a')
      elif c >= 'A' and c <= 'F': 10 + ord(c) - ord('A')
      else: raise newException(WalletError, "bad address hex")
    result[i] = byte(nib(hi) * 16 + nib(lo))

method describe*(a: EvmAdapter): ChainDescriptor =
  ChainDescriptor(chain: a.chainId, displayName: "EVM " & a.chainId,
                  nativeAsset: a.native, accountForms: @[afPublic],
                  finality: finImmediate)   # anvil fixture; a public network is finProbabilistic

method accounts*(a: EvmAdapter, ks: Keystore): seq[Account] =
  @[Account(chain: a.chainId, form: afPublic, id: addrHex(ks.address()))]

method assets*(a: EvmAdapter): seq[AssetId] = a.native & a.tokens

method balance*(a: EvmAdapter, account: Account, asset: AssetId): Amount =
  let owner = toAddress(account.id)
  let hexQty =
    if asset.kind == akNative:
      a.rpc("eth_getBalance", %*[addrHex(owner), "latest"]).getStr()
    else:
      a.rpc("eth_call", %*[{"to": asset.reference, "data": erc20BalanceOfData(owner)}, "latest"]).getStr()
  if hexQty.len == 0: raise newException(WalletError, "empty balance result")
  amount(asset, hexToDec(hexQty))

method estimateFee*(a: EvmAdapter, frm: Account, to: string, amt: Amount): FeeEstimate =
  let gasPrice = hexToDec(a.rpc("eth_gasPrice", %*[]).getStr())
  let gas = if amt.asset.kind == akNative: 21000 else: 65000
  FeeEstimate(fee: amount(a.native, mulSmall(gasPrice, gas)),
              note: "gas " & $gas & " @ " & formatUnits(gasPrice, 9) & " gwei")

method prepareTransfer*(a: EvmAdapter, frm: Account, to: string, amt: Amount): PreparedTx =
  let payload =
    if amt.asset.kind == akNative:
      $(%*{"to": to, "value": "0x" & decToHex(amt.raw)})
    else:
      $(%*{"to": amt.asset.reference, "data": erc20TransferData(toAddress(to), amt.raw)})
  PreparedTx(chain: a.chainId, frm: frm, to: to, amount: amt,
             fee: a.estimateFee(frm, to, amt), payload: payload)

method submit*(a: EvmAdapter, tx: PreparedTx, ks: Keystore): TxRef =
  ## anvil unlocks `from`, so eth_sendTransaction needs no client-side signing.
  ## A real network needs RLP + secp256k1 signing (ks.sign) — deferred with the
  ## live-node work; the fixture path is honest for the anvil settlement we run.
  if not a.fromUnlocked:
    raise newException(WalletError, "client-side EVM tx signing not implemented (needs a live node)")
  let p = parseJson(tx.payload)
  var call = %*{"from": tx.frm.id, "gas": "0x100000"}
  for k, v in p: call[k] = v
  let txHash = a.rpc("eth_sendTransaction", %*[call]).getStr()
  TxRef(chain: a.chainId, id: txHash)

method finality*(a: EvmAdapter, txRef: TxRef): Finality =
  let r = a.rpc("eth_getTransactionReceipt", %*[txRef.id])
  if r.kind == JNull: return Finality(status: fsPending, detail: "no receipt yet")
  let status = r{"status"}.getStr("0x0")
  if status == "0x1": Finality(status: fsFinal, detail: "receipt status 1")
  else: Finality(status: fsFailed, detail: "receipt status 0")
