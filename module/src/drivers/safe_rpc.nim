## Safe on-chain leg (P2): assemble execTransaction calldata, submit it over JSON-RPC,
## and watch the receipt. No indexer or Safe service — just the user's RPC endpoint
## (invariant 8: untrusted, user-configurable infrastructure). std/httpclient only,
## no external web3 dependency.

import std/[httpclient, json, strutils]
import ../hashing/keccak256
import ./safe

proc strBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc enc256(x: uint64): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 8: result[31-i] = byte((x shr uint64(8*i)) and 0xFF'u64)

proc encAddr(a: Address): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 20: result[12+i] = a[i]

proc pad32(b: seq[byte]): seq[byte] =
  result = b
  while result.len mod 32 != 0: result.add 0'u8

proc toHex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b:
    result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)]

proc assembleExecTransaction*(to: Address, value: uint64, data: seq[byte],
                              signatures: seq[byte]): seq[byte] =
  ## ABI-encode execTransaction(address,uint256,bytes,bytes). Signatures must be
  ## the owner sigs concatenated, sorted by signer address ascending (Safe's dedup).
  let sel = keccak256(strBytes("execTransaction(address,uint256,bytes,bytes)"))
  result = @[sel[0], sel[1], sel[2], sel[3]]
  let dataPadded = pad32(data)
  result.add encAddr(to)                                   # to
  result.add enc256(value)                                 # value
  result.add enc256(128'u64)                               # offset to data (4 head words)
  result.add enc256(uint64(128 + 32 + dataPadded.len))     # offset to signatures
  result.add enc256(uint64(data.len)); result.add dataPadded            # data
  result.add enc256(uint64(signatures.len)); result.add pad32(signatures) # signatures

# ── minimal JSON-RPC over the user's endpoint ─────────────────────────────────
proc rpc(url, meth: string, params: JsonNode): JsonNode =
  let client = newHttpClient()
  defer: client.close()
  let body = %*{"jsonrpc": "2.0", "id": 1, "method": meth, "params": params}
  let resp = client.request(url, httpMethod = HttpPost, body = $body,
                            headers = newHttpHeaders({"Content-Type": "application/json"}))
  parseJson(resp.body){"result"}

proc submitExecTransaction*(url: string, fromAddr, safe: Address, calldata: seq[byte]): string =
  ## Submit via the user's RPC (anvil unlocks `fromAddr`). Returns the tx hash.
  rpc(url, "eth_sendTransaction", %*[{
    "from": toHex0x(fromAddr), "to": toHex0x(safe),
    "data": toHex0x(calldata), "gas": "0x100000"}]).getStr()

proc watchReceiptStatus*(url, txHash: string): int =
  ## Poll for the receipt; returns 1 on success, 0 on revert, -1 if not yet mined.
  ## (invariant: finality is observed from the chain, never asserted by a service.)
  let r = rpc(url, "eth_getTransactionReceipt", %*[txHash])
  if r.isNil or r.kind == JNull: return -1
  if parseHexInt(r{"status"}.getStr("0x0")) == 1: 1 else: 0

proc getBalance*(url: string, a: Address): string =
  rpc(url, "eth_getBalance", %*[toHex0x(a), "latest"]).getStr()

proc hexToU64(h: string): uint64 =
  ## Parse a 0x-prefixed big-endian hex word as uint64. Leading zeros (a 32-byte
  ## word carrying a small value) contribute nothing, so a demo-range nonce is exact.
  var s = h
  if s.len >= 2 and s[0] == '0' and (s[1] in {'x', 'X'}): s = s[2 .. ^1]
  for c in s:
    let d = case c
      of '0'..'9': int(c) - int('0')
      of 'a'..'f': int(c) - int('a') + 10
      of 'A'..'F': int(c) - int('A') + 10
      else: 0
    result = result * 16 + uint64(d)

proc safeNonce*(url: string, safe: Address): uint64 =
  ## The Safe's current on-chain nonce — the value the NEXT execTransaction must use,
  ## and which the safeTxHash commits to (invariant 2). Read via `eth_call nonce()`;
  ## a fresh Safe returns 0, and it increments by one per settled execTransaction, so
  ## reading it at propose time lets sequential settles each use the right nonce
  ## instead of a hardcoded 0 (only the first of which the Safe would accept).
  let sel = keccak256(strBytes("nonce()"))
  let data = @[sel[0], sel[1], sel[2], sel[3]]
  let r = rpc(url, "eth_call", %*[{"to": toHex0x(safe), "data": toHex0x(data)}, "latest"])
  if r.isNil or r.kind == JNull: return 0
  hexToU64(r.getStr("0x0"))

proc probeRpc*(url: string): tuple[ok: bool, chainId: int, detail: string] =
  ## A cheap liveness probe of the user's RPC endpoint (invariant 8: untrusted,
  ## user-chosen infra, so its reachability must be *visible*, never assumed).
  ## eth_chainId with a short timeout — reachable + the chain it reports, or the
  ## error. Never raises: a failed probe is a real answer (down), not an exception.
  try:
    let client = newHttpClient(timeout = 1500)
    defer: client.close()
    let body = %*{"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}
    let resp = client.request(url, httpMethod = HttpPost, body = $body,
                              headers = newHttpHeaders({"Content-Type": "application/json"}))
    let j = parseJson(resp.body)
    if j.kind == JObject and j.hasKey("result"):
      let cid = parseHexInt(j["result"].getStr("0x0"))
      return (true, cid, "chain " & $cid)
    if j.kind == JObject and j.hasKey("error"):
      return (false, -1, j["error"]{"message"}.getStr("rpc error"))
    return (false, -1, "no result")
  except CatchableError as e:
    return (false, -1, e.msg)
