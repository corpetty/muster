## exo-3b3.15 (P5-09): a Safe's nonce is read strictly. The safeTxHash commits to it
## (invariant 2), so a nonce() answer that is not a uint64 quantity is a failed read: a
## value above 2^64 − 1 is refused rather than wrapped, and a non-hex digit is refused
## rather than read as 0. Through the platform endpoint hook (no network), as
## parts_tx_sender_test drives eth_rpc_module.

import std/[json, strutils]
import ../src/wallet/[chain_endpoint, rpc_budget]
import ../src/drivers/safe_rpc
import ../src/crypto/secp256k1

const Ep = "logos:eth_rpc_module/11155111"
var answer: JsonNode

proc fakeRpc(chainId: int, meth: string, params: JsonNode, budgetMs: int): JsonNode {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: %*{"ok": true, "result": answer, "route": "proxied"}

setPlatformRpc(fakeRpc)
var safe: Address
safe[19] = 0x5a

proc nonceOf(word: string): tuple[ok: bool, n: uint64, err: string] =
  answer = %word
  try: (true, safeNonce(Ep, safe), "")
  except RpcError as e: (false, 0'u64, e.msg)

# ── 1. a well-formed 32-byte word reads exactly ──────────────────────────────────
block:
  let r = nonceOf("0x" & repeat('0', 62) & "07")
  doAssert r.ok and r.n == 7, $r
  let top = nonceOf("0x" & repeat('0', 48) & repeat('f', 16))
  doAssert top.ok and top.n == high(uint64), $top
  echo "1. a nonce word reads exactly, up to 2^64 - 1 OK"

# ── 2. above 2^64 - 1: refused, never wrapped ────────────────────────────────────
block:
  let r = nonceOf("0x" & repeat('0', 47) & "1" & repeat('0', 15) & "3")   # 2^64 + 3
  doAssert not r.ok, "a nonce above 2^64 wrapped to " & $r.n
  echo "2. a nonce above 2^64 is refused OK"

# ── 3. a non-hex digit: refused, never read as 0 ─────────────────────────────────
block:
  let r = nonceOf("0x" & repeat('0', 62) & "g1")
  doAssert not r.ok, "a non-hex nonce read as " & $r.n
  echo "3. a non-hex nonce is refused OK"

echo "safe_nonce_strict_test: all OK"
