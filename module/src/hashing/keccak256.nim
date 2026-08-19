## Keccak-256 (Ethereum's pre-NIST Keccak, padding 0x01), pure Nim, dependency-free.
##
## Needed for EIP-712 / the Safe driver's safeTxHash (P2). Vendored for the same
## reason as SHA-256: the signing path hashes with a digest we control end to end.
## Verified against known vectors (empty and "abc") in tests.

type Keccak256Digest* = array[32, byte]

const RC: array[24, uint64] = [
  0x0000000000000001'u64, 0x0000000000008082'u64, 0x800000000000808a'u64,
  0x8000000080008000'u64, 0x000000000000808b'u64, 0x0000000080000001'u64,
  0x8000000080008081'u64, 0x8000000000008009'u64, 0x000000000000008a'u64,
  0x0000000000000088'u64, 0x0000000080008009'u64, 0x000000008000000a'u64,
  0x000000008000808b'u64, 0x800000000000008b'u64, 0x8000000000008089'u64,
  0x8000000000008003'u64, 0x8000000000008002'u64, 0x8000000000000080'u64,
  0x000000000000800a'u64, 0x800000008000000a'u64, 0x8000000080008081'u64,
  0x8000000000008080'u64, 0x0000000080000001'u64, 0x8000000080008008'u64]

const rotc: array[24, int] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
                              27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
const piln: array[24, int] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
                              15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]

func rotl(x: uint64, n: int): uint64 {.inline.} =
  (x shl uint64(n)) or (x shr uint64(64 - n))

proc keccakF(st: var array[25, uint64]) =
  var bc: array[5, uint64]
  for round in 0 ..< 24:
    for i in 0 ..< 5:
      bc[i] = st[i] xor st[i+5] xor st[i+10] xor st[i+15] xor st[i+20]
    for i in 0 ..< 5:
      let t = bc[(i+4) mod 5] xor rotl(bc[(i+1) mod 5], 1)
      var j = 0
      while j < 25: (st[j+i] = st[j+i] xor t; j += 5)
    var t = st[1]
    for i in 0 ..< 24:
      let j = piln[i]
      let tmp = st[j]
      st[j] = rotl(t, rotc[i])
      t = tmp
    var j = 0
    while j < 25:
      for i in 0 ..< 5: bc[i] = st[j+i]
      for i in 0 ..< 5: st[j+i] = st[j+i] xor ((not bc[(i+1) mod 5]) and bc[(i+2) mod 5])
      j += 5
    st[0] = st[0] xor RC[round]

proc keccak256*(msg: openArray[byte]): Keccak256Digest =
  const rate = 136
  var st: array[25, uint64]
  var offset = 0
  while offset + rate <= msg.len:
    for k in 0 ..< rate:
      st[k div 8] = st[k div 8] xor (uint64(msg[offset+k]) shl uint64(8 * (k mod 8)))
    keccakF(st)
    offset += rate
  var buf: array[rate, byte]
  let rem = msg.len - offset
  for k in 0 ..< rem: buf[k] = msg[offset+k]
  buf[rem] = 0x01'u8                       # keccak padding (not SHA3's 0x06)
  buf[rate-1] = buf[rate-1] xor 0x80'u8
  for k in 0 ..< rate:
    st[k div 8] = st[k div 8] xor (uint64(buf[k]) shl uint64(8 * (k mod 8)))
  keccakF(st)
  for k in 0 ..< 32:
    result[k] = byte((st[k div 8] shr uint64(8 * (k mod 8))) and 0xFF'u64)

proc toHex*(d: Keccak256Digest): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(64)
  for b in d:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 0x0F)]
