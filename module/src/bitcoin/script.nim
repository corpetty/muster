## Bitcoin scripts a multisig family builds (exo-a50.2.1): pushes, the P2WSH
## `sortedmulti` witnessScript (BIP-383), the tapscript `multi_a` / `sortedmulti_a` leaf
## (BIP-387), and the P2WSH / P2TR scriptPubKeys.

import std/algorithm
import ../hashing/sha256
import ./tx

const
  OP_0* = 0x00'u8
  OP_PUSHDATA1* = 0x4c'u8
  OP_PUSHDATA2* = 0x4d'u8
  OP_1* = 0x51'u8
  OP_CHECKSIG* = 0xac'u8
  OP_CHECKMULTISIG* = 0xae'u8
  OP_CHECKSIGADD* = 0xba'u8
  OP_NUMEQUAL* = 0x9c'u8

proc pushData*(d: openArray[byte]): seq[byte] =
  if d.len <= 75: result = @[byte(d.len)]
  elif d.len <= 255: result = @[OP_PUSHDATA1, byte(d.len)]
  elif d.len <= 65535: result = @[OP_PUSHDATA2, byte(d.len and 0xff), byte(d.len shr 8)]
  else: raise newException(BtcError, "push too large")
  result.add @d

proc pushNum*(n: int): seq[byte] =
  ## a small number as a script opcode (OP_0, OP_1..OP_16) or a minimal CScriptNum push
  if n == 0: return @[OP_0]
  if n >= 1 and n <= 16: return @[byte(0x50 + n)]
  var v = n
  var b: seq[byte]
  while v > 0: (b.add byte(v and 0xff); v = v shr 8)
  if (b[^1] and 0x80) != 0: b.add 0x00
  pushData(b)

proc cmpBytes(a, b: seq[byte]): int =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  cmp(a.len, b.len)

proc sortedMultiScript*(k: int, pubkeys: seq[seq[byte]]): seq[byte] =
  ## `sortedmulti(k, …)`: OP_k <keys sorted lexicographically> OP_n OP_CHECKMULTISIG,
  ## over 33-byte compressed keys. Sorting makes the script (so the address) independent
  ## of the order the keys were listed in.
  if k < 1 or k > pubkeys.len or pubkeys.len > 20: raise newException(BtcError, "sortedmulti needs 1 ≤ k ≤ n ≤ 20")
  var ks = pubkeys
  for p in ks:
    if p.len != 33: raise newException(BtcError, "sortedmulti takes 33-byte compressed keys")
  ks.sort(cmpBytes)
  result = pushNum(k)
  for p in ks: result.add pushData(p)
  result.add pushNum(ks.len)
  result.add OP_CHECKMULTISIG

proc multiAScript*(k: int, xonly: seq[seq[byte]], sorted = true): seq[byte] =
  ## `multi_a` / `sortedmulti_a` (BIP-387): <K1> OP_CHECKSIG <K2> OP_CHECKSIGADD …
  ## <Kn> OP_CHECKSIGADD <k> OP_NUMEQUAL, over 32-byte x-only keys.
  if k < 1 or k > xonly.len: raise newException(BtcError, "multi_a needs 1 ≤ k ≤ n")
  var ks = xonly
  for p in ks:
    if p.len != 32: raise newException(BtcError, "multi_a takes 32-byte x-only keys")
  if sorted: ks.sort(cmpBytes)
  for i, p in ks:
    result.add pushData(p)
    result.add (if i == 0: OP_CHECKSIG else: OP_CHECKSIGADD)
  result.add pushNum(k)
  result.add OP_NUMEQUAL

proc sortedKeys*(keys: seq[seq[byte]]): seq[seq[byte]] =
  result = keys
  result.sort(cmpBytes)

proc p2wshScriptPubKey*(witnessScript: openArray[byte]): seq[byte] =
  @[OP_0, 0x20'u8] & @(sha256(witnessScript))

proc p2trScriptPubKey*(outputKey: openArray[byte]): seq[byte] =
  if outputKey.len != 32: raise newException(BtcError, "a taproot output key is 32 bytes")
  @[OP_1, 0x20'u8] & @outputKey
