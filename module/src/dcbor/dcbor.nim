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

# ── Decode (strict: only the canonical encoding of a value decodes) ───────────
# Used where muster must READ back bytes it (or another member) produced — the
# signature-audit file (exo-403). Anything outside the signing-path value space
# (floats, indefinite lengths, tags, undefined) is refused, and a byte sequence
# decodes only if re-encoding the result reproduces it exactly: non-shortest
# integers, unsorted or duplicate map keys, and trailing bytes are all refused, so
# a value has exactly one accepted encoding (invariant 5).

proc decodeAt(b: openArray[byte], pos: var int, depth: int): CborValue =
  if depth > 64: raise newException(CborError, "nesting too deep")
  if pos >= b.len: raise newException(CborError, "truncated")
  let ib = b[pos]; inc pos
  let major = ib shr 5
  let ai = ib and 0x1F
  var arg: uint64
  case ai
  of 0'u8 .. 23'u8: arg = uint64(ai)
  of 24'u8, 25'u8, 26'u8, 27'u8:
    let n = 1 shl int(ai - 24)
    if pos + n > b.len: raise newException(CborError, "truncated")
    for i in 0 ..< n: arg = (arg shl 8) or uint64(b[pos + i])
    pos += n
  else: raise newException(CborError, "indefinite-length or reserved head")
  case major
  of 0: result = cbUint(arg)
  of 1: result = CborValue(kind: ckNint, n: arg)
  of 2, 3:
    if arg > uint64(b.len - pos): raise newException(CborError, "truncated")
    let n = int(arg)
    if major == 2:
      result = cbBytes(@(b[pos ..< pos + n]))
    else:
      var t = newString(n)
      for i in 0 ..< n: t[i] = char(b[pos + i])
      result = cbText(t)
    pos += n
  of 4:
    if arg > uint64(b.len - pos): raise newException(CborError, "truncated")
    var items: seq[CborValue]
    for _ in 0 ..< int(arg): items.add decodeAt(b, pos, depth + 1)
    result = cbArray(items)
  of 5:
    if arg > uint64(b.len - pos): raise newException(CborError, "truncated")
    var pairs: seq[(CborValue, CborValue)]
    for _ in 0 ..< int(arg):
      let k = decodeAt(b, pos, depth + 1)
      pairs.add (k, decodeAt(b, pos, depth + 1))
    result = cbMap(pairs)
  of 7:
    case ai
    of 20'u8: result = cbBool(false)
    of 21'u8: result = cbBool(true)
    of 22'u8: result = cbNull()
    else: raise newException(CborError, "float / simple value not permitted")
  else: raise newException(CborError, "tags are not permitted")

proc decode*(b: seq[byte]): CborValue =
  ## Decode exactly one canonical value filling `b`, or raise CborError.
  var pos = 0
  result = decodeAt(b, pos, 0)
  if pos != b.len: raise newException(CborError, "trailing bytes")
  if encode(result) != b: raise newException(CborError, "not the canonical encoding")

proc field*(m: CborValue, key: string): CborValue =
  ## A text-keyed map entry, or raise CborError naming the missing key.
  if m == nil or m.kind != ckMap: raise newException(CborError, "not a map (wanted '" & key & "')")
  for (k, v) in m.pairs:
    if k.kind == ckText and k.t == key: return v
  raise newException(CborError, "missing field '" & key & "'")
