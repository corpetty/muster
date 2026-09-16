## getOwners() ABI decode (exo-45e K3): the Safe owner set is read FROM THE CHAIN, so
## the address[] return must decode exactly — a wrong decode would mis-grade authority.
## Pure decode (no network): decodeAddressArray over crafted eth_call payloads. Links
## libsecp256k1 (Address) — see tests/README.md ($SECP).

import ../src/drivers/safe_rpc
import ../src/crypto/secp256k1

proc addrOf(b: byte): Address = (for i in 0 ..< 20: result[i] = b)
proc word(hexByte: string): string = (result = ""; for i in 0 ..< 32: result.add hexByte)
proc addrWord(b: byte): string =
  result = ""
  for i in 0 ..< 12: result.add "00"        # 12 bytes of left padding
  var hb = ""
  const d = "0123456789abcdef"
  hb.add d[int(b shr 4)]; hb.add d[int(b and 0x0F)]
  for i in 0 ..< 20: result.add hb           # 20 bytes = the address

# ── 1. a 2-owner return decodes to exactly those addresses, right-aligned ─────────
block:
  # [offset=0x20][len=2][owner0][owner1]
  let payload = "0x" & word("00")[0..61] & "20" &   # offset word ending 0x20
                word("00")[0..61] & "02" &          # length = 2
                addrWord(0x11) & addrWord(0x22)
  let owners = decodeAddressArray(payload)
  doAssert owners.len == 2, "two owners decode: got " & $owners.len
  doAssert owners[0] == addrOf(0x11) and owners[1] == addrOf(0x22)
  echo "1. a 2-owner getOwners() return decodes to exactly those addresses OK"

# ── 2. an empty owner set decodes to @[] ──────────────────────────────────────────
block:
  let payload = "0x" & word("00")[0..61] & "20" & word("00")   # offset + length 0
  doAssert decodeAddressArray(payload).len == 0
  echo "2. an empty owner set decodes to @[] OK"

# ── 3. a short/garbage payload is @[] (never a fabricated owner) ──────────────────
block:
  doAssert decodeAddressArray("0x").len == 0
  doAssert decodeAddressArray("0xdeadbeef").len == 0
  echo "3. a short/garbage payload decodes to @[] — never a fabricated owner OK"

echo "safe_owners_test: all OK"
