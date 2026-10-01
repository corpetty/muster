## Pure LEZ wire encodings — the parts of talking to lez_core that are just bytes, so
## they unit-test without the module loaded. Ported from the working demo (Zone.h's
## amountLe16Hex). Design: docs/design/lez-adapter.md.

import std/[strutils, json]

proc decToLe16*(dec: string): array[16, byte] =
  ## A non-negative decimal amount → 16 little-endian bytes (the zone takes every
  ## amount as a u128 in this form). Repeated /256 by hand,
  ## so it needs no bignum dep and handles the full u128 range.
  var digits = dec.strip()
  if digits.len == 0: digits = "0"
  for c in digits:
    if c notin {'0'..'9'}: raise newException(ValueError, "non-decimal amount: " & dec)
  var i = 0
  while digits.len > 0 and digits != "0" and i < 16:
    # divide the decimal string by 256, remainder is the next LE byte
    var rem = 0
    var q = ""
    for c in digits:
      let cur = rem * 10 + (ord(c) - ord('0'))
      q.add chr(ord('0') + (cur div 256))
      rem = cur mod 256
    result[i] = byte(rem)
    # strip leading zeros of the quotient
    var k = 0
    while k < q.len - 1 and q[k] == '0': inc k
    digits = q[k .. ^1]
    inc i
  if digits.len > 0 and digits != "0":
    raise newException(ValueError, "amount exceeds u128: " & dec)

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc amountLe16Hex*(raw: string): string =
  ## The 16-byte little-endian hex the zone takes for every amount (Zone.h).
  toHex(decToLe16(raw))

proc u128Le16Hex*(v: uint64): string =
  ## A u64 as the same 16-byte LE hex — for a PoW solution counter.
  var b: array[16, byte]
  var x = v
  for i in 0 ..< 8: (b[i] = byte(x and 0xFF); x = x shr 8)
  toHex(b)

proc fromHex(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc keyNodeJson*(npk, vpk: string): string =
  ## The `to_keys_json` a shielded/private transfer takes — exactly get_private_account_keys'
  ## output shape (lez_core v0.3.0): {nullifier_public_key, viewing_public_key}.
  $(%*{"nullifier_public_key": npk, "viewing_public_key": vpk})

proc parseKeyNode*(json: string): tuple[npk, vpk: string] =
  ## Read npk/vpk out of get_private_account_keys' JSON (or "" on a malformed read —
  ## the adapter turns an empty key node into a raise, never a silent bad address).
  try:
    let j = parseJson(json)
    (npk: j{"nullifier_public_key"}.getStr(""), vpk: j{"viewing_public_key"}.getStr(""))
  except CatchableError:
    (npk: "", vpk: "")
