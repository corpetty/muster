## Client-side EVM tx signing verified against the canonical EIP-155 test vector
## (from the EIP itself): key 0x4646…4646, chainId 1, and the exact raw signed
## transaction. This proves the whole path — nim-eth RLP + our keystore-seam
## signing + V/R/S assembly — is byte-correct, offline (no node).
## Needs the nim-eth + nim-secp256k1 closures on the path (see tests/README.md).

import std/strutils
import stint
import ../src/wallet/evm_sign
import ../src/crypto/secp256k1

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc addr20(hex: string): array[20, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc toHexLower(b: seq[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0xF)])

# The EIP-155 example transaction and its expected signed encoding.
let sk = key("0x4646464646464646464646464646464646464646464646464646464646464646")
let signer = proc(h: array[32, byte]): Signature65 = signRecoverable(h, sk)

let raw = signLegacyTransfer(signer, chain = 1, nonce = 9,
  gasPrice = 20_000_000_000'u64, gasLimit = 21_000'u64,
  to = addr20("0x3535353535353535353535353535353535353535"),
  value = u256"1000000000000000000", data = @[])

const expected =
  "f86c098504a817c8008252089435353535353535353535353535353535353535358" &
  "80de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71" &
  "ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc642" &
  "14b297fb1966a3b6d83"

doAssert toHexLower(raw) == expected, "signed tx must match the EIP-155 vector:\n" &
  toHexLower(raw) & "\n" & expected
echo "1. EIP-155 legacy signed tx matches the canonical vector OK"

echo "wallet_sign_test: all OK"
