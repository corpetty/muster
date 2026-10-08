## Is this 32-byte public key one wallet2 accepts in an address? (exo-dcc.5)
##
## monero-project/monero `cryptonote_basic_impl.cpp` `check_address` accepts a key that is
## not the identity and lies in the prime-order subgroup (`rct::isInMainSubgroup`). That
## is `rctOps.cpp` `toPointCheckOrder`: `ge_frombytes_vartime` decompresses it, then
## l·P must be the identity. `crypto-ops.c` `ge_frombytes_vartime` refuses:
##   - y ≥ p (`fe_frombytes_vartime`'s canonical check; the top bit is x's sign),
##   - a y with no x on the curve (neither v·x² = u nor v·x² = −u),
##   - x = 0 with the sign bit set.
## Reproduced here over edwards25519 (−x² + y² = 1 + d·x²·y²) in pure Nim on stint.
##
## Pure and NOT constant time: it reads only public keys, never a secret.

import stint

type Fe = UInt256

let
  P = UInt256.fromHex("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed")
  L = UInt256.fromHex("1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed")
  Zero = u256(0)
  One = u256(1)

proc fadd(a, b: Fe): Fe = addmod(a, b, P)
proc fsub(a, b: Fe): Fe = submod(a, b, P)
proc fmul(a, b: Fe): Fe = mulmod(a, b, P)
proc fpow(a, e: Fe): Fe = powmod(a, e, P)

let
  D = fmul(P - u256(121665), fpow(u256(121666), P - u256(2)))   # d = −121665/121666
  D2 = fadd(D, D)
  SqrtM1 = fpow(u256(2), (P - One) div u256(4))                 # 2^((p−1)/4) = √−1
  ExpP58 = (P - u256(5)) div u256(8)

type Ext = object
  ## extended coordinates: x = X/Z, y = Y/Z, x·y = T/Z
  x, y, z, t: Fe

proc add(p, q: Ext): Ext =
  ## add-2008-hwcd-3 for a = −1: complete on edwards25519 (d is not a square), so it
  ## also doubles and handles the identity and torsion points.
  let a = fmul(fsub(p.y, p.x), fsub(q.y, q.x))
  let b = fmul(fadd(p.y, p.x), fadd(q.y, q.x))
  let c = fmul(fmul(p.t, D2), q.t)
  let d = fmul(fadd(p.z, p.z), q.z)
  let e = fsub(b, a)
  let f = fsub(d, c)
  let g = fadd(d, c)
  let h = fadd(b, a)
  Ext(x: fmul(e, f), y: fmul(g, h), t: fmul(e, h), z: fmul(f, g))

proc isIdentity(p: Ext): bool = p.x.isZero and p.y == p.z

proc decompress(key: array[32, byte], pt: var Ext): bool =
  ## ge_frombytes_vartime, step for step.
  var yb = key
  let sign = (yb[31] shr 7) and 1
  yb[31] = yb[31] and 0x7f
  let y = UInt256.fromBytesLE(yb)
  if y >= P: return false                          # fe_frombytes_vartime: not canonical
  let yy = fmul(y, y)
  let u = fsub(yy, One)                            # u = y² − 1
  let v = fadd(fmul(D, yy), One)                   # v = d·y² + 1
  let v3 = fmul(fmul(v, v), v)
  let v7 = fmul(fmul(v3, v3), v)
  var x = fmul(fmul(u, v3), fpow(fmul(u, v7), ExpP58))   # x = u·v³·(u·v⁷)^((p−5)/8)
  let vxx = fmul(fmul(x, x), v)
  if vxx != u:
    if fadd(vxx, u) != Zero: return false          # no square root: not on the curve
    x = fmul(x, SqrtM1)
  if (if x.isOdd: 1'u8 else: 0'u8) != sign:
    if x.isZero: return false                      # x = 0 cannot carry a sign
    x = P - x
  pt = Ext(x: x, y: y, z: One, t: fmul(x, y))
  true

proc decompresses*(key: array[32, byte]): bool =
  ## The key encodes a point on the curve (any subgroup).
  var pt: Ext
  decompress(key, pt)

proc inPrimeOrderSubgroup(p: Ext): bool =
  ## l·P = identity, by double-and-add over l's bits (toPointCheckOrder's ge_scalarmult).
  var r = Ext(x: Zero, y: One, z: One, t: Zero)
  for i in countdown(252, 0):
    r = add(r, r)
    if L.getBit(i): r = add(r, p)
  r.isIdentity

proc isValidKey*(key: array[32, byte]): bool =
  ## check_address's valid_key: a point, not the identity, in the prime-order subgroup.
  var pt: Ext
  if not decompress(key, pt): return false
  if pt.x.isZero and pt.y == One: return false     # point != rct::identity()
  inPrimeOrderSubgroup(pt)
