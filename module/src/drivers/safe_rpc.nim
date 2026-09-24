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

proc assembleExecTransaction*(tx: SafeTx, signatures: seq[byte]): seq[byte] =
  ## ABI-encode the real Safe's execTransaction(address to, uint256 value, bytes data,
  ## uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address
  ## gasToken, address refundReceiver, bytes signatures) — selector 0x6a761202 — with
  ## every SafeTx field where the contract reads it (exo-a50.1.4). Signatures must be
  ## the owner sigs concatenated, sorted by signer address ascending (Safe's dedup).
  let sel = keccak256(strBytes("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)"))
  result = @[sel[0], sel[1], sel[2], sel[3]]
  let dataPadded = pad32(tx.data)
  const head = 10'u64 * 32
  result.add encAddr(tx.to)
  result.add enc256(tx.value)
  result.add enc256(head)                                         # offset to data
  result.add enc256(uint64(tx.operation))
  result.add enc256(tx.safeTxGas)
  result.add enc256(tx.baseGas)
  result.add enc256(tx.gasPrice)
  result.add encAddr(tx.gasToken)
  result.add encAddr(tx.refundReceiver)
  result.add enc256(head + 32 + uint64(dataPadded.len))           # offset to signatures
  result.add enc256(uint64(tx.data.len)); result.add dataPadded
  result.add enc256(uint64(signatures.len)); result.add pad32(signatures)

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

proc decodeAddressArray*(hex: string): seq[Address] =
  ## Decode an ABI `address[]` return: [offset:32][len:32][word:32]*len, each word a
  ## right-aligned 20-byte address. Returns @[] for an empty/short/odd payload.
  var s = hex
  if s.len >= 2 and s[0] == '0' and (s[1] in {'x', 'X'}): s = s[2 .. ^1]
  if s.len < 128: return @[]                     # need at least offset + length words
  let n = int(hexToU64(s[64 ..< 128]))           # the length word (word #2)
  for i in 0 ..< n:
    let base = 128 + i * 64                        # word #(3+i)
    if base + 64 > s.len: break
    let word = s[base ..< base + 64]
    var a: Address
    for j in 0 ..< 20:                             # last 20 bytes of the 32-byte word
      let off = 24 + j * 2
      a[j] = byte(hexToU64(word[off ..< off + 2]))
    result.add a

proc getOwners*(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] =
  ## The Safe's owner set, read from the chain via `eth_call getOwners()` (F-10:
  ## attested by the user's RPC; supply a state root elsewhere for verified-locally).
  ## `known` is false when the read fails or the RPC is unreachable — the caller must
  ## report unknown, never a fabricated owner set (rule s4, contracts/specs/derived-exo-45e).
  ## Never raises: a failed read is a real answer (not known), not an exception.
  let sel = keccak256(strBytes("getOwners()"))
  let data = @[sel[0], sel[1], sel[2], sel[3]]
  try:
    let r = rpc(url, "eth_call", %*[{"to": toHex0x(safe), "data": toHex0x(data)}, "latest"])
    if r.isNil or r.kind == JNull or r.getStr("").len == 0:
      return (false, @[], "getOwners() returned no data")
    (true, decodeAddressArray(r.getStr()), "read from chain")
  except CatchableError as e:
    (false, @[], "RPC unreachable: " & e.msg)

proc ethCall*(url: string, to: Address, data: seq[byte]): string =
  ## A raw `eth_call` at latest; the hex result ("" on no data). Raises on transport
  ## failure — callers that must report unknown wrap it.
  let r = rpc(url, "eth_call", %*[{"to": toHex0x(to), "data": toHex0x(data)}, "latest"])
  if r.isNil or r.kind == JNull: "" else: r.getStr("")

const GuardSlot* = "0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8"
  ## keccak256("guard_manager.guard.address") — where a Safe stores its transaction guard

proc decodeModulesPage*(hex: string): seq[Address] =
  ## Decode getModulesPaginated's (address[] array, address next): [offset][next]
  ## [len][item]* — the array is at the offset the first word names.
  var s = hex
  if s.len >= 2 and s[0] == '0' and (s[1] in {'x', 'X'}): s = s[2 .. ^1]
  if s.len < 192: return @[]
  let off = int(hexToU64(s[0 ..< 64])) * 2          # byte offset → hex chars
  if off + 64 > s.len: return @[]
  let n = int(hexToU64(s[off ..< off + 64]))
  for i in 0 ..< n:
    let base = off + 64 + i * 64
    if base + 64 > s.len: break
    var a: Address
    for j in 0 ..< 20:
      let o = base + 24 + j * 2
      a[j] = byte(hexToU64(s[o ..< o + 2]))
    result.add a

proc guardFromSlot*(word: string): string =
  ## The guard address from the guard storage slot's word; "" when none is set.
  var s = word
  if s.len >= 2 and s[0] == '0' and (s[1] in {'x', 'X'}): s = s[2 .. ^1]
  if s.len < 40 or s.allCharsInSet({'0'}): return ""
  "0x" & s[^40 .. ^1].toLowerAscii()

proc getModules*(url: string, safe: Address): tuple[known: bool, modules: seq[Address], detail: string] =
  ## The Safe's enabled modules (getModulesPaginated from the sentinel, first 50). A
  ## module executes WITHOUT the owners' threshold — a way around the rule. Never raises.
  let sel = keccak256(strBytes("getModulesPaginated(address,uint256)"))
  var data = @[sel[0], sel[1], sel[2], sel[3]]
  var sentinel: Address
  sentinel[19] = 1
  data.add encAddr(sentinel); data.add enc256(50'u64)
  try:
    let r = rpc(url, "eth_call", %*[{"to": toHex0x(safe), "data": toHex0x(data)}, "latest"])
    let h = (if r.isNil or r.kind == JNull: "" else: r.getStr(""))
    if h.len <= 2: return (false, @[], "getModulesPaginated() returned no data")
    (true, decodeModulesPage(h), "read from chain")
  except CatchableError as e:
    (false, @[], "RPC unreachable: " & e.msg)

proc getGuard*(url: string, safe: Address): tuple[known: bool, guard: string, detail: string] =
  ## The Safe's transaction guard, read from its storage slot ("" when none is set).
  try:
    let r = rpc(url, "eth_getStorageAt", %*[toHex0x(safe), GuardSlot, "latest"])
    let h = (if r.isNil or r.kind == JNull: "" else: r.getStr(""))
    if h.len <= 2: return (false, "", "guard slot returned no data")
    (true, guardFromSlot(h), "read from chain")
  except CatchableError as e:
    (false, "", "RPC unreachable: " & e.msg)

proc getThreshold*(url: string, safe: Address): tuple[known: bool, threshold: int, detail: string] =
  ## The Safe's threshold, read from the chain via `eth_call getThreshold()` — with
  ## getOwners, what a member's disclosure of the account is checked against
  ## (exo-a50.1.3). Never raises; `known` is false when the read fails.
  let sel = keccak256(strBytes("getThreshold()"))
  let data = @[sel[0], sel[1], sel[2], sel[3]]
  try:
    let r = rpc(url, "eth_call", %*[{"to": toHex0x(safe), "data": toHex0x(data)}, "latest"])
    let h = (if r.isNil or r.kind == JNull: "" else: r.getStr(""))
    if h.len <= 2: return (false, 0, "getThreshold() returned no data")
    (true, parseHexInt(h[max(2, h.len - 16) .. ^1]), "read from chain")
  except CatchableError as e:
    (false, 0, "RPC unreachable: " & e.msg)

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
