## Safe execTransaction assembly (secp256k1-linked — see tests/README.md).
## Pins the deterministic half of on-chain submission: the well-known selector,
## ascending-signer signature packing, and the calldata layout.

import ../src/drivers/safe
import ../src/drivers/safe_exec
import ../src/crypto/secp256k1

proc nib(c: char): int =
  if c in '0'..'9': ord(c) - ord('0')
  elif c in 'a'..'f': ord(c) - ord('a') + 10
  else: ord(c) - ord('A') + 10
proc hex32(s: string): array[32, byte] =
  for i in 0 ..< 32: result[i] = byte(nib(s[2*i]) * 16 + nib(s[2*i+1]))

proc readU64(b: openArray[byte], wordStart: int): uint64 =
  for i in 0 ..< 8: result = (result shl 8) or uint64(b[wordStart + 24 + i])

# ── 1. selector is the well-known Safe execTransaction selector 0x6a761202 ──
let sel = execSelector()
doAssert sel == [0x6a'u8, 0x76, 0x12, 0x02],
  "execTransaction selector must be 0x6a761202"

# ── build a SafeTx + its safeTxHash, and two anvil owner signatures ──
let sk0 = hex32("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let sk1 = hex32("59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
let a0 = addressOf(sk0)   # 0xf39F… (higher)
let a1 = addressOf(sk1)   # 0x7099… (lower)

var tx: SafeTx
tx.value = 1000
tx.nonce = 0
let chainId = 31337'u64
var safeAddr: Address
safeAddr[19] = 0xaa      # some fixed Safe address
let hashSeq = safeTxHash(tx, chainId, safeAddr)
var hash: array[32, byte]
for i in 0 ..< 32: hash[i] = hashSeq[i]

let s0 = signRecoverable(hash, sk0)
let s1 = signRecoverable(hash, sk1)

# ── 2. packSignatures orders by recovered signer ASCENDING ──
# Pass them in the "wrong" order (a0 first) — packing must sort a1 (lower) first.
let packed = packSignatures(hash, @[s0, s1])
doAssert packed.len == 130, "two 65-byte sigs -> 130 bytes"
var first: Signature65
for i in 0 ..< 65: first[i] = packed[i]
doAssert ecrecover(hash, first) == a1, "the lower-address owner's signature packs first"
doAssert a1[0] < a0[0], "sanity: anvil owner1 address is below owner0"

# ── 3. encodeExecTransaction layout: selector, offsets, signatures tail ──
let calldata = encodeExecTransaction(tx, packed)
doAssert calldata.len == 4 + 320 + 32 + 0 + 32 + 160,
  "empty data (32) + 130-byte sigs padded to 160 (+32 len) -> 548 bytes, got " & $calldata.len
for i in 0 ..< 4: doAssert calldata[i] == sel[i], "calldata starts with the selector"
# head word 1 = value (1000); word 2 = data offset (320); word 9 = sigs offset (352)
doAssert readU64(calldata, 4 + 1*32) == 1000'u64, "value encoded in head"
doAssert readU64(calldata, 4 + 2*32) == 320'u64, "data offset = head length"
doAssert readU64(calldata, 4 + 9*32) == 352'u64, "signatures offset = 320 + 32 (empty data)"
doAssert readU64(calldata, 4 + 352) == 130'u64, "signatures length word = 130"

# ── 4. MiniSafe fixture encoder (4-arg execTransaction) — layout ──
let mini = encodeMiniSafeExec(a0, 1000'u64, @[], packed)
let msel = miniSafeExecSelector()
for i in 0 ..< 4: doAssert mini[i] == msel[i], "minisafe calldata starts with its selector"
doAssert mini.len == 4 + 128 + 32 + 32 + 160,
  "minisafe calldata: 4 head words + empty-data tail + 130-byte sigs padded to 160"
doAssert readU64(mini, 4 + 2*32) == 128'u64, "minisafe data offset (4 head words)"
doAssert readU64(mini, 4 + 3*32) == 160'u64, "minisafe signatures offset = 128 + 32 (empty data)"
doAssert readU64(mini, 4 + 160) == 130'u64, "minisafe signatures length word = 130"

echo "safe_exec: real-Safe 0x6a761202 + MiniSafe encoders, ascending-signer packing, layouts OK"
