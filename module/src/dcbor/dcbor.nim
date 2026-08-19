## Deterministic CBOR (CDE) encoder for Muster signing-path values.
##
## Spec: `contracts/specs/derived-exo-d7c.spec.json` (invariant 5). The only
## contract is that a value maps to exactly one byte sequence:
##   s1  same value, any construction order -> identical bytes
##   s2  map keys in bytewise-lexicographic order of their ENCODED bytes,
##       never length-first (RFC 8949 §4.2.3 "CDE", not §4.2.1 core canonical)
##   s3  integers in shortest form, no non-canonical padding
##   s4  no indefinite-length items, no floats — such inputs are REJECTED,
##       never silently coerced to some other encoding
##
## This is ours to own: the platform's CBOR is non-canonical, so determinism
## on the signing path cannot be inherited (ADR-009). Pure stdlib — no external
## dependency — so the invariant lives entirely in code we control.

import std/algorithm

type
  CborError* = object of CatchableError

  CborKind* = enum
    ckUint, ckNint, ckBytes, ckText, ckArray, ckMap, ckBool, ckNull,
    ckFloat, ckIndefinite   ## ckFloat / ckIndefinite exist only to be rejected (s4)

  CborValue* = ref object
    case kind*: CborKind
    of ckUint: u*: uint64
    of ckNint: n*: uint64        ## CBOR argument for major 1 == -1 - value
    of ckBytes: b*: seq[byte]
    of ckText: t*: string
    of ckArray: arr*: seq[CborValue]
    of ckMap: pairs*: seq[(CborValue, CborValue)]
    of ckBool: bo*: bool
    of ckNull: discard
    of ckFloat: f*: float64
    of ckIndefinite: discard

# ── Constructors ──────────────────────────────────────────────────────────────
proc cbUint*(u: uint64): CborValue = CborValue(kind: ckUint, u: u)

proc cbInt*(i: int64): CborValue =
  ## Signed integer -> unsigned (major 0) or negative (major 1), shortest form.
  if i >= 0: cbUint(uint64(i))
  else: CborValue(kind: ckNint, n: uint64(-(i + 1)))

proc cbBytes*(b: seq[byte]): CborValue = CborValue(kind: ckBytes, b: b)
proc cbText*(t: string): CborValue = CborValue(kind: ckText, t: t)
proc cbArray*(items: seq[CborValue]): CborValue = CborValue(kind: ckArray, arr: items)
proc cbMap*(pairs: seq[(CborValue, CborValue)]): CborValue = CborValue(kind: ckMap, pairs: pairs)
proc cbBool*(bo: bool): CborValue = CborValue(kind: ckBool, bo: bo)
proc cbNull*(): CborValue = CborValue(kind: ckNull)
proc cbFloat*(f: float64): CborValue = CborValue(kind: ckFloat, f: f)
proc cbIndefinite*(): CborValue = CborValue(kind: ckIndefinite)

# ── Head encoding (major type + argument, shortest form — s3) ─────────────────
proc encodeHead(major: byte, arg: uint64): seq[byte] =
  let mt = major shl 5
  if arg < 24'u64:
    result = @[mt or byte(arg)]
  elif arg <= 0xFF'u64:
    result = @[mt or 24'u8, byte(arg)]
  elif arg <= 0xFFFF'u64:
    result = @[mt or 25'u8, byte((arg shr 8) and 0xFF), byte(arg and 0xFF)]
  elif arg <= 0xFFFF_FFFF'u64:
    result = @[mt or 26'u8,
      byte((arg shr 24) and 0xFF), byte((arg shr 16) and 0xFF),
      byte((arg shr 8) and 0xFF), byte(arg and 0xFF)]
  else:
    result = @[mt or 27'u8]
    for i in countdown(7, 0):
      result.add byte((arg shr (i * 8)) and 0xFF)

# ── Bytewise-lexicographic byte comparison (s2 — NOT length-first) ────────────
proc cmpBytes*(a, b: seq[byte]): int =
  ## Pure lexicographic order over byte values. A shorter sequence sorts before
  ## a longer one ONLY when it is a strict prefix — length is never a primary
  ## key. This is exactly what separates CDE ordering from RFC 8949 §4.2.1.
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] != b[i]:
      return (if a[i] < b[i]: -1 else: 1)
  cmp(a.len, b.len)

# ── Encode ────────────────────────────────────────────────────────────────────
proc encode*(v: CborValue): seq[byte] =
  ## Encode a value to its single canonical byte sequence, or raise CborError
  ## for an input outside the signing-path value space (float / indefinite).
  if v == nil:
    raise newException(CborError, "nil CborValue")
  case v.kind
  of ckUint:
    result = encodeHead(0, v.u)
  of ckNint:
    result = encodeHead(1, v.n)
  of ckBytes:
    result = encodeHead(2, uint64(v.b.len))
    result.add v.b
  of ckText:
    result = encodeHead(3, uint64(v.t.len))
    for c in v.t: result.add byte(c)
  of ckArray:
    result = encodeHead(4, uint64(v.arr.len))
    for it in v.arr: result.add encode(it)
  of ckMap:
    # Encode each pair, then order by the key's own encoded bytes (bytewise-lex).
    var enc = newSeq[(seq[byte], seq[byte])](v.pairs.len)
    for i, kv in v.pairs:
      enc[i] = (encode(kv[0]), encode(kv[1]))
    enc.sort(proc(x, y: (seq[byte], seq[byte])): int = cmpBytes(x[0], y[0]))
    # Reject duplicate keys — two equal encoded keys have no canonical order.
    for i in 1 ..< enc.len:
      if cmpBytes(enc[i-1][0], enc[i][0]) == 0:
        raise newException(CborError, "duplicate map key on signing path")
    result = encodeHead(5, uint64(enc.len))
    for (kb, vb) in enc:
      result.add kb
      result.add vb
  of ckBool:
    result = @[if v.bo: 0xF5'u8 else: 0xF4'u8]
  of ckNull:
    result = @[0xF6'u8]
  of ckFloat:
    raise newException(CborError, "floating-point is not permitted on the signing path")
  of ckIndefinite:
    raise newException(CborError, "indefinite-length is not permitted on the signing path")

proc toHex*(bytes: seq[byte]): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 0x0F)]
