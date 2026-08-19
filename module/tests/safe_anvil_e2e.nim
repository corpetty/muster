## P2 end-to-end against anvil: collect 2-of-3 owner signatures over the safeTxHash,
## assemble execTransaction, submit over JSON-RPC, watch the receipt, and confirm
## the transfer executed — with NO indexer or Safe service in the loop. A successful
## execTransaction is itself the cross-validation that muster's local safeTxHash
## matches the contract's on-chain getTxHash (else checkSignatures reverts).
## Usage: safe_anvil_e2e <safeAddr> [rpcUrl]
import std/[os, algorithm, strutils]
import ../src/drivers/safe
import ../src/drivers/safe_rpc
import ../src/crypto/secp256k1
import ../src/dcbor/dcbor
import ../src/intents/materialization

proc hexToBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2..^1]
  for i in 0 ..< h.len div 2:
    result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc toAddr(s: string): Address =
  let b = hexToBytes(s); (for i in 0 ..< 20: result[i] = b[i])
proc toKey(s: string): array[32, byte] =
  let b = hexToBytes(s); (for i in 0 ..< 32: result[i] = b[i])

proc cmpAddr(a, b: Address): int =
  for i in 0 ..< 20:
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  0

let rpc = (if paramCount() >= 2: paramStr(2) else: "http://127.0.0.1:8545")
let safeAddr = toAddr(paramStr(1))
# anvil accounts 0 and 1 as the two signing owners
let k0 = toKey("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let k1 = toKey("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
let relayer = addressOf(k0)                       # who pays gas / relays the call
let recipient = toAddr("0x00000000000000000000000000000000DeaDBeef")
let value = 1_000_000_000_000_000_000'u64         # 1 ETH

let drv = newSafeDriver(chainId = 31337, safe = safeAddr,
                        owners = @[addressOf(k0), addressOf(k1)], threshold = 2)
let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
  ("to", cbText("0x00000000000000000000000000000000DeaDBeef")),
  ("value", cbUint(value)), ("nonce", cbUint(0'u64))])
let mat = canonicalizeSafe(drv, effect)           # muster's local safeTxHash
var hash: array[32, byte]
for i in 0 ..< 32: hash[i] = mat.bytes[i]

# Collect the two owner signatures, sorted by signer address ascending (Safe dedup).
var signed: seq[(Address, Signature65)]
signed.add (addressOf(k0), signRecoverable(hash, k0))
signed.add (addressOf(k1), signRecoverable(hash, k1))
signed.sort(proc(a, b: (Address, Signature65)): int = cmpAddr(a[0], b[0]))
var sigs: seq[byte]
for (_, s) in signed: sigs.add @s

echo "recipient balance before: ", getBalance(rpc, recipient)
let calldata = assembleExecTransaction(recipient, value, @[], sigs)
let txHash = submitExecTransaction(rpc, relayer, safeAddr, calldata)
echo "submitted execTransaction: ", txHash

var status = -1
for i in 0 .. 50:
  status = watchReceiptStatus(rpc, txHash)
  if status >= 0: break
  sleep(200)
doAssert status == 1, "execTransaction did not succeed on-chain (status " & $status & ")"
echo "execTransaction succeeded on-chain (checkSignatures passed -> local safeTxHash matched)"

let bal = getBalance(rpc, recipient)
echo "recipient balance after:  ", bal
doAssert parseHexInt(bal) == 1_000_000_000_000_000_000, "recipient did not receive 1 ETH"
echo "P2 e2e: 2-of-3 collected off-chain, executed on-chain, no indexer: OK"
