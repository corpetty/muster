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
