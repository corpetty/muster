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
import stint
import ./types
import ./adapter
import ./verify
import ./evm_sign
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
    chainNum: uint64             ## numeric chain id (for EIP-155 signing)
    rpcUrl: string
    native: AssetId
    tokens: seq[AssetId]         ## reference = the token contract address (0x…)
    fromUnlocked: bool           ## anvil unlocks accounts → eth_sendTransaction needs no client-side signing

proc newEvmAdapter*(chainId, rpcUrl: string, tokens: seq[AssetId] = @[],
                    fromUnlocked = true): EvmAdapter =
  let native = AssetId(chain: chainId, symbol: "ETH", kind: akNative, decimals: 18)
  let digits = chainId.split(':')[^1]        # "evm:31337" -> 31337
  EvmAdapter(chainId: chainId, chainNum: uint64(parseBiggestUInt(digits)),
             rpcUrl: rpcUrl, native: native, tokens: tokens, fromUnlocked: fromUnlocked)

proc bytesHexLower(b: seq[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0xF)])

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
  ## Anvil unlocks `from`, so eth_sendTransaction needs no client-side signing. For
  ## any other node, sign the EIP-155 transaction with nim-eth + the keystore seam
  ## (the key never leaves the keystore) and broadcast the raw bytes.
  let p = parseJson(tx.payload)
  if a.fromUnlocked:
    var call = %*{"from": tx.frm.id, "gas": "0x100000"}
    for k, v in p: call[k] = v
    return TxRef(chain: a.chainId, id: a.rpc("eth_sendTransaction", %*[call]).getStr())

  # Real client-side signing (RLP + secp256k1 via ks.sign), then eth_sendRawTransaction.
  let value = if p.hasKey("value"): UInt256.fromHex(p["value"].getStr()) else: 0.u256
  let data = if p.hasKey("data"): verify.hexBytes(p["data"].getStr()) else: @[]
  let nonce = uint64(fromHex[uint64](a.rpc("eth_getTransactionCount", %*[tx.frm.id, "pending"]).getStr()))
  let gasPrice = uint64(fromHex[uint64](a.rpc("eth_gasPrice", %*[]).getStr()))
  let gasLimit = if data.len == 0: 21_000'u64 else: 65_000'u64
  var toArr: array[20, byte]
  let tb = verify.hexBytes(p{"to"}.getStr())
  for i in 0 ..< min(20, tb.len): toArr[i] = tb[i]
  let signer = proc(h: array[32, byte]): Signature65 = ks.sign(h)
  let raw = signLegacyTransfer(signer, a.chainNum, nonce, gasPrice, gasLimit, toArr, value, data)
  TxRef(chain: a.chainId, id: a.rpc("eth_sendRawTransaction", %*["0x" & bytesHexLower(raw)]).getStr())

proc verifiedBalance*(a: EvmAdapter, account: Account, stateRootHex: string): Amount =
  ## A `verified-locally` balance (F-10): ask the untrusted provider for eth_getProof,
  ## then verify the account's Merkle proof against a TRUSTED state root (from a
  ## beacon-light-client sidecar — the Nimbus verified proxy in REST mode). If the
  ## proof does not verify, this raises — the provider's number never passes as real.
  ## Unlike `balance` (which trusts the RPC), this trusts only the state root.
  let owner = toAddress(account.id)
  let r = a.rpc("eth_getProof", %*[addrHex(owner), newJArray(), "latest"])
  var proof: seq[seq[byte]]
  for n in r{"accountProof"}: proof.add verify.hexBytes(n.getStr())
  var root: array[32, byte]
  let rb = verify.hexBytes(stateRootHex)
  for i in 0 ..< min(32, rb.len): root[31 - i] = rb[rb.len - 1 - i]
  let v = verifyAccountFields(proof, root, owner,
    nonce = uint64(fromHex[uint64](r{"nonce"}.getStr("0x0"))),
    balanceHex = r{"balance"}.getStr("0x0"),
    storageHashHex = r{"storageHash"}.getStr(),
    codeHashHex = r{"codeHash"}.getStr())
  amount(a.native, v.balanceRaw)

method finality*(a: EvmAdapter, txRef: TxRef): Finality =
  let r = a.rpc("eth_getTransactionReceipt", %*[txRef.id])
  if r.kind == JNull: return Finality(status: fsPending, detail: "no receipt yet")
  let status = r{"status"}.getStr("0x0")
  if status == "0x1": Finality(status: fsFinal, detail: "receipt status 1")
  else: Finality(status: fsFailed, detail: "receipt status 0")
