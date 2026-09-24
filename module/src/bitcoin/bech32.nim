## Segwit addresses: bech32 (BIP-173, witness v0) and bech32m (BIP-350, v1+)
## (exo-a50.2.1). Pinned to the BIP-350 vectors.

import std/strutils
import ./tx

const Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
const Bech32Const = 1'u32
const Bech32mConst = 0x2bc830a3'u32

proc polymod(values: seq[byte]): uint32 =
  const gen = [0x3b6a57b2'u32, 0x26508e6d'u32, 0x1ea119fa'u32, 0x3d4233dd'u32, 0x2a1462b3'u32]
  var chk = 1'u32
  for v in values:
    let b = chk shr 25
    chk = ((chk and 0x1ffffff) shl 5) xor uint32(v)
    for i in 0 ..< 5:
      if ((b shr uint32(i)) and 1) == 1: chk = chk xor gen[i]
  chk

proc hrpExpand(hrp: string): seq[byte] =
  for c in hrp: result.add byte(ord(c) shr 5)
  result.add 0
  for c in hrp: result.add byte(ord(c) and 31)

proc convertBits(data: openArray[byte], frm, to: int, pad: bool): seq[byte] =
  var acc = 0
  var bits = 0
  let maxv = (1 shl to) - 1
  for v in data:
    if (int(v) shr frm) != 0: raise newException(BtcError, "bad bech32 data value")
    acc = (acc shl frm) or int(v)
    bits += frm
    while bits >= to:
      bits -= to
      result.add byte((acc shr bits) and maxv)
  if pad:
    if bits > 0: result.add byte((acc shl (to - bits)) and maxv)
  elif bits >= frm or ((acc shl (to - bits)) and maxv) != 0:
    raise newException(BtcError, "bad bech32 padding")

proc encodeSegwitAddress*(hrp: string, witver: int, program: openArray[byte]): string =
  let data = @[byte(witver)] & convertBits(program, 8, 5, true)
  let c = (if witver == 0: Bech32Const else: Bech32mConst)
  let pm = polymod(hrpExpand(hrp) & data & @[0'u8, 0, 0, 0, 0, 0]) xor c
  result = hrp & "1"
  for d in data: result.add Charset[int(d)]
  for i in 0 ..< 6: result.add Charset[int((pm shr uint32(5 * (5 - i))) and 31)]

proc decodeSegwitAddress*(hrp, address: string): tuple[witver: int, program: seq[byte]] =
  ## Raises BtcError on anything BIP-173/350 rejects (mixed case, bad checksum, wrong
  ## variant for the version, bad program length, wrong hrp).
  if address.len > 90: raise newException(BtcError, "too long")
  if address != address.toLowerAscii() and address != address.toUpperAscii():
    raise newException(BtcError, "mixed case")
  let a = address.toLowerAscii()
  let pos = a.rfind('1')
  if pos < 1 or pos + 7 > a.len: raise newException(BtcError, "no separator / too short")
  if a[0 ..< pos] != hrp.toLowerAscii(): raise newException(BtcError, "wrong hrp")
  var data: seq[byte]
  for c in a[pos + 1 .. ^1]:
    let i = Charset.find(c)
    if i < 0: raise newException(BtcError, "bad character")
    data.add byte(i)
  let pm = polymod(hrpExpand(a[0 ..< pos]) & data)
  if data.len < 7: raise newException(BtcError, "no witness version")
  let witver = int(data[0])
  if witver > 16: raise newException(BtcError, "bad witness version")
  let want = (if witver == 0: Bech32Const else: Bech32mConst)
  if pm != want: raise newException(BtcError, "bad checksum (or the wrong bech32 variant for v" & $witver & ")")
  let prog = convertBits(data[1 ..< data.len - 6], 5, 8, false)
  if prog.len < 2 or prog.len > 40: raise newException(BtcError, "bad program length")
  if witver == 0 and prog.len != 20 and prog.len != 32: raise newException(BtcError, "bad v0 program length")
  (witver, prog)

proc scriptPubKeyOfAddress*(hrp, address: string): seq[byte] =
  let (v, p) = decodeSegwitAddress(hrp, address)
  @[(if v == 0: 0x00'u8 else: byte(0x50 + v)), byte(p.len)] & p
