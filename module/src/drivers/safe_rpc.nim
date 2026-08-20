## Safe on-chain transport (P2): submit execTransaction calldata over JSON-RPC and
## watch the receipt. No indexer or Safe service — just the user's RPC endpoint
## (invariant 8: untrusted, user-configurable infrastructure). std/httpclient only,
## no external web3 dependency.
##
## Calldata ASSEMBLY (real Safe 1.4.1 or the MiniSafe fixture) + signature packing
## live in safe_exec.nim; this file is only the wire.

import std/[httpclient, json, strutils]
import ./safe    # Address

proc toHex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b:
    result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)]

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
