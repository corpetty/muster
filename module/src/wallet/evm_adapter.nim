## The EVM ChainAdapter — native ETH + ERC-20 tokens over the user's JSON-RPC
## endpoint (invariant 8: untrusted, user-configured; no indexer, no third-party
## API). Balance reads are `verified-locally` facts the client performs itself
## (F-10). This is the same chain the Safe driver settles on; the wallet is the
## account-level view of it, distinct from the coordinated intent path.
##
## The pure pieces — ERC-20 calldata assembly, hex<->decimal balance parsing,
## account derivation — are exported and unit-tested without a node; the RPC
## methods are thin wrappers over them.

import std/[json, strutils]
import stint
import ./types
import ./adapter
import ./verify
import ./evm_sign
import ./evm_rpc
import ./chain_endpoint   # a platform endpoint: eth_rpc_module (exo-d4d.3)
import ./tx_sender        # …and its one sender, tx_sender_module (exo-d4d.5)
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
    owner: string                ## the account this wallet holds, when not the keystore's own:
                                 ## under the platform, the person's keystore_module account (exo-d4d)

proc newEvmAdapter*(chainId, rpcUrl: string, tokens: seq[AssetId] = @[],
                    fromUnlocked = true, owner = ""): EvmAdapter =
  let native = AssetId(chain: chainId, symbol: "ETH", kind: akNative, decimals: 18)
  let digits = chainId.split(':')[^1]        # "evm:31337" -> 31337
  EvmAdapter(chainId: chainId, chainNum: uint64(parseBiggestUInt(digits)),
             rpcUrl: rpcUrl, native: native, tokens: tokens, fromUnlocked: fromUnlocked,
             owner: owner.toLowerAscii())

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
  @[Account(chain: a.chainId, form: afPublic, id: (if a.owner.len > 0: a.owner else: addrHex(ks.address())))]

method assets*(a: EvmAdapter): seq[AssetId] = a.native & a.tokens

method balance*(a: EvmAdapter, account: Account, asset: AssetId): Amount =
  if asset.kind == akNative:
    amount(asset, rpcBalance(a.rpcUrl, account.id, "latest"))   # typed UInt256 → decimal
  else:
    let ret = rpcCall(a.rpcUrl, asset.reference,
                      verify.hexBytes(erc20BalanceOfData(toAddress(account.id))), "latest")
    var word: array[32, byte]
    if ret.len >= 32:
      for i in 0 ..< 32: word[i] = ret[ret.len - 32 + i]
    amount(asset, $UInt256.fromBytesBE(word))

method estimateFee*(a: EvmAdapter, frm: Account, to: string, amt: Amount): FeeEstimate =
  let gasPrice = rpcGasPrice(a.rpcUrl)
  let gas = if amt.asset.kind == akNative: 21_000'u64 else: 65_000'u64
  FeeEstimate(fee: amount(a.native, $(gasPrice * gas)),
              note: "gas " & $gas & " @ " & formatUnits($gasPrice, 9) & " gwei")

method prepareTransfer*(a: EvmAdapter, frm: Account, to: string, amt: Amount): PreparedTx =
  let payload =
    if amt.asset.kind == akNative:
      $(%*{"to": to, "value": "0x" & decToHex(amt.raw)})
    else:
      $(%*{"to": amt.asset.reference, "data": erc20TransferData(toAddress(to), amt.raw)})
  PreparedTx(chain: a.chainId, frm: frm, to: to, amount: amt,
             fee: a.estimateFee(frm, to, amt), payload: payload)

proc payloadGas(p: JsonNode, default: uint64): uint64 =
  ## a contract call (a Safe execTransaction) names its own gas limit; a plain
  ## transfer / ERC-20 keeps the adapter's defaults
  if p.hasKey("gas") and p["gas"].kind == JInt and p["gas"].getInt() > 0: uint64(p["gas"].getInt())
  else: default

proc parsePayload(p: JsonNode): tuple[toHex: string, value: UInt256, data: seq[byte]] =
  let value = if p.hasKey("value"): UInt256.fromHex(p["value"].getStr()) else: 0.u256
  let data = if p.hasKey("data"): verify.hexBytes(p["data"].getStr()) else: @[]
  (p{"to"}.getStr(), value, data)

proc submitThroughPlatform(a: EvmAdapter, tx: PreparedTx, pj: JsonNode, value: UInt256): TxRef =
  ## On a platform endpoint (Basecamp): the payload's one call goes to tx_sender_module —
  ## prepare, check its legs are exactly that call, send. A person approves in the signer;
  ## the TxRef is a marker until the sender broadcasts (finality polls it). Muster signs
  ## nothing and holds no nonce here: the device's one sender does.
  if not hasTxSender(): raise newException(WalletError, "no tx_sender_module on this host: install it from Basecamp")
  let call = TxCall(to: pj{"to"}.getStr().toLowerAscii(), value: $value,
                    data: (let d = pj{"data"}.getStr(""); if d == "0x": "" else: d.toLowerAscii()))
  let purpose = pj{"purpose"}.getStr("A transaction agreed in a Muster room")
  let req = requestJson(int(a.chainNum), tx.frm.id, call, purpose,
                        (if pj{"meta"} != nil: pj["meta"] else: newJObject()))
  let mismatch = legsMismatch(senderCall("prepare", %*[$req]), call)
  if mismatch.len > 0: raise newException(WalletError, mismatch)
  let sent = senderCall("send", %*[$req])
  if sent == nil: raise newException(WalletError, "tx_sender_module did not answer send")
  if not sent{"ok"}.getBool(false):
    raise newException(WalletError, sent{"error"}.getStr("tx_sender_module refused the send"))
  let rid = sent{"requestId"}.getStr()
  if rid.len == 0: raise newException(WalletError, "tx_sender_module answered no request id")
  sendBook.add(rid, sent{"handle"}.getStr(), pj{"meta"}{"muster"}{"intent"}.getStr(""), "", purpose)
  TxRef(chain: a.chainId, id: markerOf(rid))

proc resolvedRef*(r: TxRef): string =
  ## The chain's own reference for a TxRef: itself, or for a send through the platform the
  ## hash the sender broadcast ("" until it has).
  let rid = requestOfMarker(r.id)
  if rid.len == 0: r.id else: sendBook.hashOf(rid)

method submit*(a: EvmAdapter, tx: PreparedTx, ks: Keystore): TxRef =
  ## Anvil unlocks `from`, so eth_sendTransaction needs no client-side signing. For
  ## any other node, sign the EIP-155 transaction with nim-eth + the keystore seam
  ## (the key never leaves the keystore) and broadcast the raw bytes. On a platform
  ## endpoint, tx_sender_module sends it instead (submitThroughPlatform).
  let pj = parseJson(tx.payload)
  let (toHex, value, data) = parsePayload(pj)
  if a.rpcUrl.isPlatform and not a.fromUnlocked: return a.submitThroughPlatform(tx, pj, value)
  if a.fromUnlocked:
    let gas = payloadGas(pj, if data.len == 0: 100_000'u64 else: 120_000'u64)
    return TxRef(chain: a.chainId,
                 id: rpcSendTransaction(a.rpcUrl, tx.frm.id, toHex, value, data, gas))

  # Real client-side signing (RLP + secp256k1 via ks.sign), then eth_sendRawTransaction.
  let nonce = rpcNonce(a.rpcUrl, tx.frm.id)
  let gasPrice = rpcGasPrice(a.rpcUrl)
  let gasLimit = payloadGas(pj, if data.len == 0: 21_000'u64 else: 65_000'u64)
  var toArr: array[20, byte]
  let tb = verify.hexBytes(toHex)
  for i in 0 ..< min(20, tb.len): toArr[i] = tb[i]
  let signer = proc(h: array[32, byte]): Signature65 = ks.sign(h)
  let raw = signLegacyTransfer(signer, a.chainNum, nonce, gasPrice, gasLimit, toArr, value, data)
  TxRef(chain: a.chainId, id: rpcSendRaw(a.rpcUrl, raw))

proc verifiedBalance*(a: EvmAdapter, account: Account, stateRootHex: string): Amount =
  ## A `verified-locally` balance (F-10): ask the untrusted provider for eth_getProof,
  ## then verify the account's Merkle proof against a TRUSTED state root (from a
  ## beacon-light-client sidecar — the Nimbus verified proxy in REST mode). If the
  ## proof does not verify, this raises — the provider's number never passes as real.
  ## Unlike `balance` (which trusts the RPC), this trusts only the state root.
  let owner = toAddress(account.id)
  let (nonce, balDec, storageHex, codeHex, proof) = rpcGetProof(a.rpcUrl, account.id, "latest")
  var root: array[32, byte]
  let rb = verify.hexBytes(stateRootHex)
  for i in 0 ..< min(32, rb.len): root[31 - i] = rb[rb.len - 1 - i]
  let v = verifyAccountFields(proof, root, owner, nonce, balDec, storageHex, codeHex)
  amount(a.native, v.balanceRaw)

method finality*(a: EvmAdapter, txRef: TxRef): Finality =
  ## A failed read raises (exo-14f). The status is bound before the `case`: with the call as
  ## the selector, Nim 2.2 skips initializing `result` (every branch assigns it), so a raise
  ## returned an unbuilt Finality that the caller then destroyed — a SIGSEGV.
  var hash = txRef.id
  let rid = requestOfMarker(txRef.id)
  if rid.len > 0:
    # through the platform: the poll IS the broadcast; then the hash's receipt
    let st = pollSend(rid)
    if st.state == ssAwaiting:
      return Finality(status: fsPending, detail: (if st.blocked: "held until verified reads work again"
                                                  else: "waiting for you to approve it in the Logos Signer"))
    if st.state == ssBroadcasting: return Finality(status: fsPending, detail: "being broadcast")
    hash = sendBook.hashOf(rid)
    if hash.len == 0:
      if st.final: return Finality(status: fsFailed, detail: "the send was " & st.status &
                                     (if st.reason.len > 0: ": " & st.reason else: ""))
      return Finality(status: fsPending, detail: "the sender has not named a hash yet")
  let status = rpcReceiptStatus(a.rpcUrl, hash)
  case status
  of 1: Finality(status: fsFinal, detail: "receipt status 1")
  of 0: Finality(status: fsFailed, detail: "receipt status 0")
  else: Finality(status: fsPending, detail: "no receipt yet")
