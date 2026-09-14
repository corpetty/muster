## The pure LEZ wire encodings (P-L3): amount → 16-byte LE hex, the pinata PoW, and
## the key-node JSON. No infra, no crypto beyond sha256 — `nim r` alone.

import std/[strutils, json]
import ../src/wallet/lez_encoding
import ../src/hashing/sha256

# ── amountLe16Hex: 16-byte little-endian, the zone's amount encoding ───────────
block:
  doAssert amountLe16Hex("0") == "00000000000000000000000000000000"
  doAssert amountLe16Hex("1") == "01000000000000000000000000000000", "LE: 1 is the first byte"
  doAssert amountLe16Hex("256") == "00010000000000000000000000000000", "256 = byte[1]"
  doAssert amountLe16Hex("255") == "ff000000000000000000000000000000"
  # 2^64 sits at byte 8
  doAssert amountLe16Hex("18446744073709551616") == "00000000000000000100000000000000"
  doAssertRaises(ValueError): discard amountLe16Hex("nope")
  echo "1. amountLe16Hex — 16-byte little-endian OK"

# ── pinataSolve: a real proof-of-work the module does NOT do for you ───────────
block:
  const seed = "aabbccdd00112233445566778899aabb"   # 16-byte seed
  let solHex = pinataSolve(seed, difficulty = 1)
  # verify: sha256(seed ‖ solution_le16) has its leftmost byte zero
  var buf: seq[byte]
  for i in 0 ..< seed.len div 2: buf.add byte(parseHexInt(seed[2*i .. 2*i+1]))
  for i in 0 ..< solHex.len div 2: buf.add byte(parseHexInt(solHex[2*i .. 2*i+1]))
  doAssert sha256(buf)[0] == 0, "the returned solution actually satisfies difficulty 1"
  doAssert solHex.len == 32, "the solution is a 16-byte LE hex"
  echo "1b. pinataSolve — a verifiable PoW solution OK"

# ── key node JSON — the to_keys_json shape lez_core v0.3.0 uses ────────────────
block:
  let j = keyNodeJson("aa", "bb")
  doAssert parseJson(j)["nullifier_public_key"].getStr() == "aa"
  doAssert parseJson(j)["viewing_public_key"].getStr() == "bb"
  let kn = parseKeyNode("""{"nullifier_public_key":"cc","viewing_public_key":"dd"}""")
  doAssert kn.npk == "cc" and kn.vpk == "dd"
  doAssert parseKeyNode("garbage").npk == "", "a malformed key node reads empty, not a crash"
  echo "2. key node JSON round-trips OK"

echo "wallet_lez_encoding_test: all OK"
