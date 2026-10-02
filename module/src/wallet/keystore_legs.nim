## The legs muster hands keystore_module's request_approval (exo-149.2 K2). Pure.
##
## keystore_module signs a bundle of legs as ONE human decision (docs/specs.md
## §request_approval, logos-evm-keystore-module@2318c679). Two kinds matter here:
##   typed_data  an EIP-712 document. The keystore parses it, computes the signing hash
##               itself, and renders every field, so a human reads the SafeTx they sign.
##   digest      32 bytes signed raw (no prefix), rendered as an opaque hash beside the
##               requester's CLAIMED purpose. Used for muster's own commitments that are
##               not EIP-712 (the attestation over P) — an interim the card flags, until
##               they have typed forms (exo-149.6; docs/design/keystore-module-backend.md §4).
##
## typedDataHash is EIP-712 over the flat structs muster emits (atomic types only). It
## lets muster refuse to send a document that does not hash to what it derived, before
## a human ever sees it; the keystore still hashes the document itself, and muster checks
## the returned signature against its own hash on the way back (signerOf).

import std/[json, strutils]
import ../hashing/keccak256
import ../crypto/secp256k1
import ../drivers/safe

type KeystoreLegError* = object of CatchableError

const MaxIntentBytes* = 64 * 1024   ## keystore_module refuses a larger intent

proc fail(msg: string) {.noreturn.} = raise newException(KeystoreLegError, msg)

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)])

proc bytesOfHex*(s: string): seq[byte] =
  var h = s.strip()
  if h.startsWith("0x") or h.startsWith("0X"): h = h[2 .. ^1]
  if h.len mod 2 != 0: fail("odd-length hex")
  try:
    for i in countup(0, h.len - 2, 2): result.add byte(parseHexInt(h[i .. i + 1]))
  except ValueError: fail("not hex: " & s)

# ── the SafeTx document ──────────────────────────────────────────────────────────

proc safeTypedData*(tx: SafeTx, chainId: uint64, safe: Address): JsonNode =
  ## The SafeTx as the EIP-712 document Safe 1.4.1 signs: domain {chainId,
  ## verifyingContract}, the ten fields in the SafeTx typehash's order. uint256 values
  ## go as decimal strings (a JSON number loses precision above 2^53).
  %*{
    "types": {
      "EIP712Domain": [
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"}],
      "SafeTx": [
        {"name": "to", "type": "address"},
        {"name": "value", "type": "uint256"},
        {"name": "data", "type": "bytes"},
        {"name": "operation", "type": "uint8"},
        {"name": "safeTxGas", "type": "uint256"},
        {"name": "baseGas", "type": "uint256"},
        {"name": "gasPrice", "type": "uint256"},
        {"name": "gasToken", "type": "address"},
        {"name": "refundReceiver", "type": "address"},
        {"name": "nonce", "type": "uint256"}]},
    "primaryType": "SafeTx",
    "domain": {"chainId": chainId, "verifyingContract": hexOf(safe)},
    "message": {
      "to": hexOf(tx.to), "value": $tx.value, "data": hexOf(tx.data),
      "operation": int(tx.operation), "safeTxGas": $tx.safeTxGas, "baseGas": $tx.baseGas,
      "gasPrice": $tx.gasPrice, "gasToken": hexOf(tx.gasToken),
      "refundReceiver": hexOf(tx.refundReceiver), "nonce": $tx.nonce}}

# ── EIP-712 over flat structs ────────────────────────────────────────────────────

proc word(): seq[byte] = newSeq[byte](32)

proc uintWord(v: JsonNode, bits: int): seq[byte] =
  ## A uintN value from a JSON number, a decimal string, or a 0x hex string → 32 bytes BE.
  result = word()
  var digits = ""
  case v.kind
  of JInt: digits = $v.getBiggestInt()
  of JString: digits = v.getStr().strip()
  else: fail("uint value is neither a number nor a string")
  if digits.startsWith("0x") or digits.startsWith("0X"):
    let b = bytesOfHex(digits)
    if b.len > 32: fail("uint too wide")
    for i, x in b: result[32 - b.len + i] = x
  else:
    if digits.len == 0 or not digits.allCharsInSet(Digits): fail("not a decimal uint: " & digits)
    for c in digits:                                   # result = result * 10 + c, big-endian
      var carry = int(c) - int('0')
      for i in countdown(31, 0):
        let x = int(result[i]) * 10 + carry
        result[i] = byte(x and 0xff)
        carry = x shr 8
      if carry != 0: fail("uint overflows 256 bits")
  if bits < 256:                                       # the value must fit uintN
    for i in 0 ..< 32 - bits div 8:
      if result[i] != 0: fail("value overflows uint" & $bits)

proc encodeAtomic(typ: string, v: JsonNode): seq[byte] =
  if v == nil: fail("missing value for " & typ)
  if typ == "address":
    let b = bytesOfHex(v.getStr())
    if b.len != 20: fail("address is not 20 bytes")
    result = word()
    for i in 0 ..< 20: result[12 + i] = b[i]
  elif typ == "bool":
    result = word()
    if v.kind != JBool: fail("bool expected")
    if v.getBool(): result[31] = 1
  elif typ == "bytes":
    result = @(keccak256(bytesOfHex(v.getStr())))
  elif typ == "string":
    result = @(keccak256(v.getStr().toOpenArrayByte(0, v.getStr().high)))
  elif typ.startsWith("uint"):
    let bits = (if typ.len == 4: 256 else: (try: parseInt(typ[4 .. ^1]) except ValueError: 0))
    if bits <= 0 or bits > 256 or bits mod 8 != 0: fail("bad type " & typ)
    result = uintWord(v, bits)
  elif typ.startsWith("bytes"):
    let n = (try: parseInt(typ[5 .. ^1]) except ValueError: 0)
    if n < 1 or n > 32: fail("bad type " & typ)
    let b = bytesOfHex(v.getStr())
    if b.len != n: fail(typ & " is not " & $n & " bytes")
    result = word()
    for i in 0 ..< n: result[i] = b[i]
  else:
    fail("unsupported type " & typ & " (atomic types only)")

proc typeString(name: string, fields: JsonNode): string =
  var parts: seq[string]
  for f in fields: parts.add f["type"].getStr() & " " & f["name"].getStr()
  name & "(" & parts.join(",") & ")"

proc hashStruct(types: JsonNode, name: string, data: JsonNode): seq[byte] =
  let fields = types{name}
  if fields == nil or fields.kind != JArray: fail("no type " & name)
  if data == nil or data.kind != JObject: fail(name & " data is not an object")
  var buf = @(keccak256(typeString(name, fields).toOpenArrayByte(0, typeString(name, fields).high)))
  for f in fields:
    let typ = f["type"].getStr()
    if typ.endsWith("]") or types.hasKey(typ): fail("nested or array type " & typ & " is not supported")
    buf.add encodeAtomic(typ, data{f["name"].getStr()})
  @(keccak256(buf))

proc typedDataHash*(td: JsonNode): array[32, byte] =
  ## EIP-712: keccak256(0x19 0x01 ‖ hashStruct(EIP712Domain, domain) ‖ hashStruct(primary,
  ## message)), over flat structs. Raises KeystoreLegError on anything it cannot type.
  if td == nil or td.kind != JObject: fail("typed data is not an object")
  let types = td{"types"}
  if types == nil: fail("no types")
  let ds = hashStruct(types, "EIP712Domain", td{"domain"})
  let hs = hashStruct(types, td{"primaryType"}.getStr(), td{"message"})
  let d = keccak256(@[0x19'u8, 0x01'u8] & ds & hs)
  for i in 0 ..< 32: result[i] = d[i]

# ── legs and the intent ──────────────────────────────────────────────────────────

proc safeTxLeg*(tx: SafeTx, chainId: uint64, safe: Address): JsonNode =
  ## The Safe approval as a typed_data leg. Refuses a document that does not hash to the
  ## safeTxHash muster derived: the human would be shown one thing and the Safe count another.
  let td = safeTypedData(tx, chainId, safe)
  let want = safeTxHash(tx, chainId, safe)
  let got = typedDataHash(td)
  for i in 0 ..< 32:
    if got[i] != want[i]: fail("the SafeTx document does not hash to the safeTxHash")
  %*{"kind": "typed_data", "typed_data": td}

proc digestLeg*(d: array[32, byte], purpose: string): JsonNode =
  ## 32 bytes signed raw. The purpose is muster's claim, shown as such; it must be stated.
  if purpose.strip().len == 0: fail("a digest leg needs a stated purpose")
  %*{"kind": "digest", "digest": hexOf(d), "purpose": purpose}

proc approvalIntent*(address, purpose: string, legs: seq[JsonNode]): JsonNode =
  ## {address, purpose, legs}: one human decision over every leg. Refused before sending
  ## when it is empty or larger than the keystore accepts.
  if legs.len == 0: fail("an approval needs at least one leg")
  result = %*{"address": address, "purpose": purpose, "legs": legs}
  if ($result).len > MaxIntentBytes: fail("intent exceeds the keystore's 64 KiB")

proc signerOf*(hash: array[32, byte], sigHex: string): Address =
  ## The address a returned 65-byte signature (r‖s‖v, v as 27/28 or 0/1) recovers to over
  ## `hash` — muster's own hash, never one the keystore reports.
  let b = bytesOfHex(sigHex)
  if b.len != 65: fail("a signature is 65 bytes, got " & $b.len)
  var sig: Signature65
  for i in 0 ..< 65: sig[i] = b[i]
  ecrecover(hash, sig)
