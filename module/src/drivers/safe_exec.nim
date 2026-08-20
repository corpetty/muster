## Safe execTransaction assembly (P2 — the deterministic half of on-chain
## submission). Once the owner signatures are collected, build the exact calldata
## that executes the Safe transaction: the ABI-encoded `execTransaction(...)` call,
## with the signatures packed in Safe's REQUIRED ascending-signer order (Safe's
## checkSignatures walks recovered owners strictly increasing to reject
## duplicates). Dependency-free and testable without a chain.
##
## Two encoders live here: `encodeExecTransaction` for the REAL Safe 1.4.1 10-arg
## call (selector 0x6a761202), and `encodeMiniSafeExec` for the 4-arg
## `execTransaction(address,uint256,bytes,bytes)` of the infra/anvil MiniSafe
## fixture. They share the ABI helpers and `packSignatures`; pick the one that
## matches the deployed contract. `safe_rpc.nim` is the JSON-RPC transport that
## broadcasts whichever calldata these produce.
##
## The remaining half — broadcasting this calldata to the Safe over JSON-RPC and
## watching for the receipt — lives in `safe_rpc.nim` (std/httpclient, no web3
## dep). Determinism and correctness hinge on the ASSEMBLY here, which stays pure
## and golden-tested; the transport is I/O bolted on at the infra edge.

import std/algorithm
import ../hashing/keccak256
import ../crypto/secp256k1
import ./safe            # SafeTx, Address, Signature65

# Safe 1.4.1 execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,
#                            address,address,bytes) — selector is the well-known
#                            0x6a761202 (pinned in the test as a known answer).
const EXEC_SIG = "execTransaction(address,uint256,bytes,uint8,uint256," &
                 "uint256,uint256,address,address,bytes)"

proc sbytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc execSelector*(): array[4, byte] =
  let h = keccak256(sbytes(EXEC_SIG))
  for i in 0 ..< 4: result[i] = h[i]

# ── ABI 32-byte words ──
proc word(x: uint64): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 8: result[31 - i] = byte((x shr uint64(8 * i)) and 0xFF)

proc wordAddr(a: Address): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 20: result[12 + i] = a[i]

proc pad32(b: seq[byte]): seq[byte] =
  result = b
  while result.len mod 32 != 0: result.add 0'u8

proc cmpAddr(a, b: Address): int =
  for i in 0 ..< 20:
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  0

proc packSignatures*(hash: array[32, byte], sigs: seq[Signature65]): seq[byte] =
  ## Concatenate the 65-byte owner signatures ordered by RECOVERED signer address,
  ## ascending — exactly what Safe's checkSignatures expects. Each signature must
  ## recover (callers pass verified owner signatures); a malformed one raises via
  ## ecrecover rather than silently misordering.
  var withAddr: seq[(Address, Signature65)]
  for s in sigs:
    withAddr.add (ecrecover(hash, s), s)
  withAddr.sort(proc(x, y: (Address, Signature65)): int = cmpAddr(x[0], y[0]))
  for entry in withAddr:
    for b in entry[1]: result.add b

proc encodeExecTransaction*(tx: SafeTx, packedSigs: seq[byte]): seq[byte] =
  ## selector ++ ABI(execTransaction args). Two dynamic tail params (`data`,
  ## `signatures`); the eight static params sit inline in the 10-word head.
  let sel = execSelector()
  for b in sel: result.add b

  const headLen = 10 * 32
  let dataPadded = pad32(tx.data)
  let dataOffset = uint64(headLen)
  let sigsOffset = uint64(headLen + 32 + dataPadded.len)   # after data (len word + body)

  var head: seq[byte]
  head.add wordAddr(tx.to)
  head.add word(tx.value)
  head.add word(dataOffset)
  head.add word(tx.operation.uint64)
  head.add word(tx.safeTxGas)
  head.add word(tx.baseGas)
  head.add word(tx.gasPrice)
  head.add wordAddr(tx.gasToken)
  head.add wordAddr(tx.refundReceiver)
  head.add word(sigsOffset)
  result.add head

  result.add word(uint64(tx.data.len)); result.add dataPadded
  result.add word(uint64(packedSigs.len)); result.add pad32(packedSigs)

# ── MiniSafe fixture (infra/anvil/MiniSafe.sol): a 4-arg execTransaction ─────────
# execTransaction(address to, uint256 value, bytes data, bytes signatures). This
# matches the test fixture, NOT a production Safe — use encodeExecTransaction for a
# real Safe 1.4.1 deployment.
const MINISAFE_EXEC_SIG = "execTransaction(address,uint256,bytes,bytes)"

proc miniSafeExecSelector*(): array[4, byte] =
  let h = keccak256(sbytes(MINISAFE_EXEC_SIG))
  for i in 0 ..< 4: result[i] = h[i]

proc encodeMiniSafeExec*(to: Address, value: uint64, data: seq[byte],
                         packedSigs: seq[byte]): seq[byte] =
  let sel = miniSafeExecSelector()
  for b in sel: result.add b
  let dataPadded = pad32(data)
  result.add wordAddr(to)
  result.add word(value)
  result.add word(128'u64)                             # offset to data (4 head words)
  result.add word(uint64(128 + 32 + dataPadded.len))   # offset to signatures
  result.add word(uint64(data.len)); result.add dataPadded
  result.add word(uint64(packedSigs.len)); result.add pad32(packedSigs)
