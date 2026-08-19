## Safe 1.4.1 driver — EIP-712 safeTxHash (P2, the wedge).
##
## The Safe driver's canonicalize() turns an effect into the exact bytes Safe
## owners sign: the EIP-712 safeTxHash. The client re-derives this locally
## (invariant 1) rather than trusting a proposer's copy, and because the hash
## commits to chainId, the Safe address, and the nonce, a signature is worthless
## against a different chain, Safe, or nonce (invariant 2 / the P2 wrong-chainid /
## wrong-safe / wrong-nonce rejections). keccak256 is vendored; the type hashes
## below are the published Safe 1.4.1 constants, checked in the test.
##
## Signature verification (ECDSA vs owners), assemble/submit/watch over anvil come
## next and need nim-secp256k1 + nim-web3; this file is the local, dependency-free
## canonicalization the rest of the driver hangs off.

import ../hashing/keccak256
import ../dcbor/dcbor
import ../drivers/driver
import ../intents/materialization
import ../crypto/secp256k1   # Address, Signature65, recoversToOwner
export secp256k1.Address, secp256k1.Signature65   # part of the Safe API surface

type
  SafeTx* = object
    to*: Address
    value*: uint64
    data*: seq[byte]
    operation*: uint8
    safeTxGas*: uint64
    baseGas*: uint64
    gasPrice*: uint64
    gasToken*: Address
    refundReceiver*: Address
    nonce*: uint64

proc enc256(x: uint64): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 8: result[31-i] = byte((x shr uint64(8*i)) and 0xFF'u64)

proc encAddr(a: Address): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 20: result[12+i] = a[i]

proc kdigest(parts: varargs[seq[byte]]): seq[byte] =
  var buf: seq[byte]
  for p in parts: buf.add p
  @(keccak256(buf))

proc strBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

# Published Safe 1.4.1 type hashes (verified against the on-chain constants in the test).
let DOMAIN_TYPEHASH* = kdigest(strBytes(
  "EIP712Domain(uint256 chainId,address verifyingContract)"))
let SAFE_TX_TYPEHASH* = kdigest(strBytes(
  "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas," &
  "uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"))

proc domainSeparator*(chainId: uint64, safe: Address): seq[byte] =
  kdigest(DOMAIN_TYPEHASH, enc256(chainId), encAddr(safe))

proc safeTxStructHash*(tx: SafeTx): seq[byte] =
  kdigest(SAFE_TX_TYPEHASH, encAddr(tx.to), enc256(tx.value),
          @(keccak256(tx.data)), enc256(tx.operation.uint64),
          enc256(tx.safeTxGas), enc256(tx.baseGas), enc256(tx.gasPrice),
          encAddr(tx.gasToken), encAddr(tx.refundReceiver), enc256(tx.nonce))

proc safeTxHash*(tx: SafeTx, chainId: uint64, safe: Address): seq[byte] =
  ## EIP-712: keccak256(0x19 ++ 0x01 ++ domainSeparator ++ structHash).
  kdigest(@[0x19'u8, 0x01'u8], domainSeparator(chainId, safe), safeTxStructHash(tx))

# ── The Safe driver: a 1-round, named-membership, external-finality driver whose
# canonicalize produces the safeTxHash as the materialization. ─────────────────
type SafeDriver* = ref object of Driver
  chainId*: uint64
  safe*: Address
  threshold*: int
  owners*: seq[Address]              ## the Safe's owner set
  pendingHash*: array[32, byte]      ## the safeTxHash currently being collected on

method describe*(d: SafeDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "eip712.safe.v1.4.1",
                   membership: mmNamed, finality: finExternal, threshold: d.threshold)

method verifyContribution*(d: SafeDriver, c: Contribution, round: int): bool =
  ## A contribution is a 65-byte owner ECDSA signature over the pending safeTxHash.
  ## The core never reads these bytes (invariant 6); only the driver does, here.
  if c.bytes.len != 65: return false
  var sig: Signature65
  for i in 0 ..< 65: sig[i] = c.bytes[i]
  recoversToOwner(d.pendingHash, sig, d.owners)

proc newSafeDriver*(chainId: uint64, safe: Address, owners: seq[Address] = @[],
                    threshold = 2): SafeDriver =
  SafeDriver(chainId: chainId, safe: safe, owners: owners, threshold: threshold)

proc hexNibble(c: char): byte =
  case c
  of '0'..'9': byte(ord(c) - ord('0'))
  of 'a'..'f': byte(ord(c) - ord('a') + 10)
  of 'A'..'F': byte(ord(c) - ord('A') + 10)
  else: 0'u8

proc toSafeTx*(e: Effect): SafeTx =
  ## Map a transfer effect's fields to a SafeTx. P2 v0 handles the common transfer
  ## shape; richer effect schemas extend this mapping.
  for (k, v) in e.fields:
    case k
    of "to":
      if v.kind == ckText:
        var s = v.t
        if s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'): s = s[2..^1]
        for i in 0 ..< min(20, s.len div 2):
          result.to[i] = byte((hexNibble(s[2*i]) shl 4) or hexNibble(s[2*i+1]))
    of "value":
      if v.kind == ckUint: result.value = v.u
    of "nonce":
      if v.kind == ckUint: result.nonce = v.u
    else: discard

proc canonicalizeSafe*(d: SafeDriver, e: Effect): Materialization =
  ## The Safe materialization is the safeTxHash the owners sign. Recording it as
  ## the pending hash lets verifyContribution check owner signatures against it.
  let h = safeTxHash(toSafeTx(e), d.chainId, d.safe)
  for i in 0 ..< 32: d.pendingHash[i] = h[i]
  Materialization(bytes: h)
