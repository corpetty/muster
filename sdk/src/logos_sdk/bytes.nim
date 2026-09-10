## Canonical C-ABI bytes codec — the Nim mirror of logos-rust-sdk `src/bytes.rs`.
##
## A `bstr` argument or record field does not ride the `lp_*` wire as raw bytes:
## the JSON transport is text, so bytes travel as a tagged object
## `{"_bytes": "<base64url, UNPADDED>"}`. Both SDKs encode this identically, so a
## Nim caller and a Rust (or C++) provider decode each other's payloads
## byte-for-byte. This module is the single place that tagging lives.
##
## Pure Nim, no FFI — unit-testable with `nim r`.

import std/strutils

const b64urlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

proc b64urlEncode*(data: openArray[byte]): string =
  ## URL-safe base64, UNPADDED (RFC 4648 §5 without `=`). This is the exact form
  ## the lp_* wire expects inside `{"_bytes": ...}`.
  var i = 0
  while i + 3 <= data.len:
    let n = (int(data[i]) shl 16) or (int(data[i+1]) shl 8) or int(data[i+2])
    result.add b64urlAlphabet[(n shr 18) and 63]
    result.add b64urlAlphabet[(n shr 12) and 63]
    result.add b64urlAlphabet[(n shr 6) and 63]
    result.add b64urlAlphabet[n and 63]
    i += 3
  let rem = data.len - i
  if rem == 1:
    let n = int(data[i]) shl 16
    result.add b64urlAlphabet[(n shr 18) and 63]
    result.add b64urlAlphabet[(n shr 12) and 63]
  elif rem == 2:
    let n = (int(data[i]) shl 16) or (int(data[i+1]) shl 8)
    result.add b64urlAlphabet[(n shr 18) and 63]
    result.add b64urlAlphabet[(n shr 12) and 63]
    result.add b64urlAlphabet[(n shr 6) and 63]

proc b64urlDecodeChar(c: char): int =
  case c
  of 'A'..'Z': int(c) - int('A')
  of 'a'..'z': int(c) - int('a') + 26
  of '0'..'9': int(c) - int('0') + 52
  of '-': 62
  of '_': 63
  else: -1

proc b64urlDecode*(s: string): seq[byte] =
  ## Lenient decoder: accepts padding (`=`) and standard `+`/`/` as well as the
  ## url-safe alphabet, and skips whitespace/newlines — so a payload produced by a
  ## stricter or looser peer still round-trips.
  var bits = 0
  var acc = 0
  for ch in s:
    if ch == '=': break
    var v = b64urlDecodeChar(ch)
    if v < 0:
      if ch == '+': v = 62
      elif ch == '/': v = 63
      else: continue    # skip whitespace/newlines
    acc = (acc shl 6) or v
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add byte((acc shr bits) and 0xFF)

proc bytesTag*(data: openArray[byte]): string =
  ## The JSON value for a `bstr` argument or field: `{"_bytes":"<b64url>"}`.
  ## Hand this string where a JSON value is expected (it is already valid JSON).
  "{\"_bytes\":\"" & b64urlEncode(data) & "\"}"

proc isBytesTag*(node: string): bool =
  ## True if `node` looks like a bytes-tagged JSON object. A cheap structural
  ## check; callers that hold a parsed JsonNode should test `hasKey("_bytes")`.
  node.len > 11 and node.contains("\"_bytes\"")
