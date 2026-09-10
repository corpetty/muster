## Headless unit tests for the bytes codec (no FFI, runs under `nim r`).
## The wire form is shared with logos-rust-sdk, so these vectors also pin
## cross-SDK interop.

import std/[unittest, json]
import ../src/logos_sdk/bytes

suite "bytes codec — {\"_bytes\": <b64url unpadded>}":

  test "empty":
    check b64urlEncode([]) == ""
    check b64urlDecode("") == newSeq[byte]()
    check bytesTag([]) == "{\"_bytes\":\"\"}"

  test "known vectors (url-safe, UNPADDED)":
    # "f" -> "Zg", "fo" -> "Zm8", "foo" -> "Zm9v", "foob" -> "Zm9vYg"
    check b64urlEncode(@[byte 'f']) == "Zg"
    check b64urlEncode(@[byte 'f', byte 'o']) == "Zm8"
    check b64urlEncode(@[byte 'f', byte 'o', byte 'o']) == "Zm9v"
    check b64urlEncode(@[byte 'f', byte 'o', byte 'o', byte 'b']) == "Zm9vYg"

  test "url-safe alphabet uses - and _ (never + /)":
    # bytes chosen so the sextets land on index 62 and 63
    let enc = b64urlEncode(@[byte 0xFB, byte 0xFF])
    check '-' in enc or '_' in enc
    check '+' notin enc
    check '/' notin enc

  test "round-trips arbitrary bytes":
    for n in 0 .. 260:
      var data = newSeq[byte](n)
      for i in 0 ..< n: data[i] = byte((i * 37 + 11) and 0xFF)
      check b64urlDecode(b64urlEncode(data)) == data

  test "decode is lenient (accepts padding and + /)":
    check b64urlDecode("Zm9v") == @[byte 'f', byte 'o', byte 'o']
    check b64urlDecode("Zg==") == @[byte 'f']            # padded
    check b64urlDecode("Zm9v\n") == @[byte 'f', byte 'o', byte 'o']  # whitespace skipped

  test "bytesTag is valid JSON carrying the encoding":
    let tag = bytesTag(@[byte 1, byte 2, byte 3])
    let j = parseJson(tag)
    check j.kind == JObject
    check j.hasKey("_bytes")
    check b64urlDecode(j["_bytes"].getStr()) == @[byte 1, byte 2, byte 3]

  test "isBytesTag structural check":
    check isBytesTag(bytesTag(@[byte 9]))
    check not isBytesTag("{\"other\":1}")
