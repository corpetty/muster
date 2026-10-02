## The legs muster hands keystore_module (exo-149.2 K2). Held: a Safe approval is a
## typed_data leg whose EIP-712 document hashes, under the standard, to exactly the
## safeTxHash muster derives — for a plain transfer and for a call that sets every
## SafeTx field — with Safe 1.4.1's domain and field order; the hasher refuses what it
## cannot type; a digest leg carries 32 bytes and a stated purpose; an intent refuses no
## legs and anything over the keystore's 64 KiB; and a returned signature recovers to
## its signer whether v arrives as 27/28 or 0/1. Leg shapes: keystore_module
## docs/specs.md §request_approval @2318c679.

import std/[json, strutils]
import ../src/drivers/safe
import ../src/crypto/secp256k1
import ../src/wallet/keystore_legs

proc addr20(b: byte): Address =
  for i in 0 ..< 20: result[i] = b

proc h32(s: seq[byte]): array[32, byte] =
  for i in 0 ..< 32: result[i] = s[i]

const ChainId = 31337'u64
let safeAddr = addr20(0xEB)

let plain = SafeTx(to: addr20(0x11), value: 1_000_000_000_000_000_000'u64, nonce: 7)
var full = SafeTx(to: addr20(0x22), value: high(uint64), data: @[0xa9'u8, 0x05, 0x9c, 0xbb, 0, 1, 2, 3],
                  operation: 1, safeTxGas: 50_000, baseGas: 21_000, gasPrice: 3,
                  gasToken: addr20(0x33), refundReceiver: addr20(0x44), nonce: 12)

block shape:
  let td = safeTypedData(plain, ChainId, safeAddr)
  doAssert td["primaryType"].getStr() == "SafeTx"
  var dom: seq[string]
  for f in td["types"]["EIP712Domain"]: dom.add f["type"].getStr() & " " & f["name"].getStr()
  doAssert dom == @["uint256 chainId", "address verifyingContract"], $dom
  var fields: seq[string]
  for f in td["types"]["SafeTx"]: fields.add f["type"].getStr() & " " & f["name"].getStr()
  doAssert fields.join(",") == "address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas," &
    "uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce", $fields
  doAssert td["domain"]["chainId"].getInt() == 31337
  doAssert td["domain"]["verifyingContract"].getStr() == "0x" & "eb".repeat(20)
  doAssert td["message"]["value"].getStr() == "1000000000000000000"    # uint256 as a decimal string
  doAssert td["message"]["data"].getStr() == "0x" and td["message"]["operation"].getInt() == 0
  echo "1. the SafeTx document: Safe 1.4.1's domain and field order, uint256 as decimal strings OK"

block hashesToSafeTxHash:
  for tx in [plain, full]:
    let td = safeTypedData(tx, ChainId, safeAddr)
    doAssert typedDataHash(td) == h32(safeTxHash(tx, ChainId, safeAddr)), "EIP-712 hash != safeTxHash"
  echo "2. the document hashes under EIP-712 to exactly muster's safeTxHash (plain, and every field set) OK"

block legWraps:
  let leg = safeTxLeg(full, ChainId, safeAddr)
  doAssert leg["kind"].getStr() == "typed_data" and leg["typed_data"]["primaryType"].getStr() == "SafeTx"
  doAssert typedDataHash(leg["typed_data"]) == h32(safeTxHash(full, ChainId, safeAddr))
  echo "3. safeTxLeg wraps it as a typed_data leg OK"

block hasherRefuses:
  var td = safeTypedData(plain, ChainId, safeAddr)
  td["types"]["SafeTx"].add %*{"name": "extra", "type": "Inner"}            # a nested struct
  doAssertRaises(KeystoreLegError): discard typedDataHash(td)
  var td2 = safeTypedData(plain, ChainId, safeAddr)
  td2["types"]["SafeTx"][0]["type"] = %"address[]"                          # an array
  doAssertRaises(KeystoreLegError): discard typedDataHash(td2)
  var td3 = safeTypedData(plain, ChainId, safeAddr)
  td3["message"].delete("nonce")                                             # a missing field
  doAssertRaises(KeystoreLegError): discard typedDataHash(td3)
  echo "4. the hasher refuses a nested struct, an array, and a missing field OK"

block digestLegs:
  var d: array[32, byte]
  for i in 0 ..< 32: d[i] = byte(i)
  let leg = digestLeg(d, "muster attestation: the inputs of this approval")
  doAssert leg["kind"].getStr() == "digest" and leg["purpose"].getStr().startsWith("muster attestation")
  doAssert leg["digest"].getStr() == "0x" & "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  doAssertRaises(KeystoreLegError): discard digestLeg(d, "")
  echo "5. a digest leg carries the 32 bytes and a stated purpose; no purpose is refused OK"

block intents:
  let leg = safeTxLeg(plain, ChainId, safeAddr)
  let it = approvalIntent("0x" & "aa".repeat(20), "approve proposal abc in room r", @[leg])
  doAssert it["address"].getStr() == "0x" & "aa".repeat(20) and it["legs"].len == 1
  doAssertRaises(KeystoreLegError): discard approvalIntent("0x" & "aa".repeat(20), "p", @[])
  var big = full
  big.data = newSeq[byte](40_000)                                            # hex doubles it: > 64 KiB
  doAssertRaises(KeystoreLegError):
    discard approvalIntent("0x" & "aa".repeat(20), "p", @[safeTxLeg(big, ChainId, safeAddr)])
  echo "6. an intent refuses no legs and anything over the keystore's 64 KiB OK"

block recovery:
  var sk: array[32, byte]
  for i in 0 ..< 32: sk[i] = byte(i + 1)
  let who = addressOf(sk)
  let h = h32(safeTxHash(full, ChainId, safeAddr))
  let sig = signRecoverable(h, sk)                   # v = 27 + recid
  var hexSig = "0x"
  for b in sig: hexSig.add toHex(b).toLowerAscii()
  doAssert signerOf(h, hexSig) == who
  var low = sig
  low[64] = byte(int(low[64]) - 27)                   # v as 0/1
  var hexLow = "0x"
  for b in low: hexLow.add toHex(b).toLowerAscii()
  doAssert signerOf(h, hexLow) == who
  doAssertRaises(KeystoreLegError): discard signerOf(h, "0x1234")
  echo "7. a returned signature recovers to its signer, v as 27/28 or 0/1; a short one is refused OK"

echo "keystore_legs_test: all passed"
