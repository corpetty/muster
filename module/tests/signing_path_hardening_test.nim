## The Safe path signs exactly what the card shows (exo-ffc, the 2026-11-22 audit P1-03),
## and the intent id is a domain-separated record (exo-c38, P1-06).
##
## A Safe effect's numbers were read as `uint64(getInt())`: a value past 64 bits (a JSON
## number Nim keeps as text), a negative one, or a string signed as 0 or wrapped, while
## the card showed what was written; an address of any length kept its first 20 bytes. Now
## every such field reaches the signed hash as written or the transaction is refused, and
## a gas refund (gasPrice > 0), which pays the executor from the Safe, is refused too.

import std/strutils
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/crypto/secp256k1
import ../src/coordination/intent_events

proc toAddr(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and h[1] in {'x', 'X'}: h = h[2 .. ^1]
  for i in 0 ..< 20: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

let drv = newSafeDriver(chainId = 31337, safe = toAddr("0x7a2088a1bFc9d81c55368AE168C2C02570cB814F"))
const To = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

proc refusal(json: string): string = drv.signRefusal(effectFromJson(json))

# ── 1. what is fine is fine ─────────────────────────────────────────────────────
doAssert refusal("""{"to":"""" & To & """","value":1000000000000000000,"nonce":0}""") == ""
doAssert refusal("""{"effect":"safe-tx","to":"""" & To & """","value":"5","nonce":"0x2","data":"0x","operation":0}""") == "",
  "a decimal or 0x string that fits is the number it says"
doAssert toSafeTx(effectFromJson("""{"effect":"safe-tx","to":"""" & To & """","value":"5","nonce":"0x2"}""")).value == 5
echo "1. a well-formed transfer and safe-tx are signed as written OK"

# ── 2. a number the card shows one way and the hash would carry another ────────
for v in ["20000000000000000000", "-1", "\"20000000000000000000\"", "\"-1\"", "\"5 wei\"", "1.5", "\"0x\"", "true"]:
  let r = refusal("""{"to":"""" & To & """","value":""" & v & ""","nonce":0}""")
  doAssert r.contains("value"), "value " & v & " is refused, got: '" & r & "'"
doAssert refusal("""{"effect":"safe-tx","to":"""" & To & """","value":0,"nonce":-3}""").contains("nonce")
echo "2. a value past 64 bits, negative, fractional or not a number is refused OK"

# ── 3. an address that is not exactly 20 bytes, data that is not whole bytes ───
let long = "0x" & To[2 .. ^1] & "abcd"
for a in [long, "0x7099", To & "zz", "70997970C51812dc3A010C7d01b50e0d17dc79Cg"]:
  doAssert refusal("""{"to":"""" & a & """","value":1,"nonce":0}""").contains("to"), "to " & a & " is refused"
block:
  let r = refusal("""{"effect":"safe-tx","to":"""" & To & """","value":0,"nonce":0,"data":"0xabc"}""")
  doAssert r.contains("data"), "odd data is refused, got: '" & r & "'"
block:
  let r = refusal("""{"effect":"safe-tx","to":"""" & To & """","value":0,"nonce":0,"refundReceiver":"0x01"}""")
  doAssert r.contains("refundReceiver"), "refundReceiver 0x01 is refused, got: '" & r & "'"
echo "3. an overlong, short or non-hex address, and odd-length data, are refused OK"

# ── 4. a gas refund pays the executor from the Safe: refused ───────────────────
doAssert refusal("""{"effect":"safe-tx","to":"""" & To & """","value":0,"nonce":0,"gasPrice":1,""" &
  """"gasToken":"0x0000000000000000000000000000000000000001","refundReceiver":"""" & To & """"}""").contains("refund")
doAssert refusal("""{"effect":"safe-tx","to":"""" & To & """","value":0,"nonce":0,"gasPrice":0,"baseGas":21000}""") == "",
  "with gasPrice 0 no refund is paid"
echo "4. a non-zero gasPrice (a refund out of the Safe) is refused OK"

# ── 5. the intent id: a domain-separated record, 128 bits ──────────────────────
let e = """{"to":"""" & To & """","value":1,"nonce":0}"""
let id = intentIdFor(e, "safe")
doAssert id.startsWith("0x") and id.len == 2 + 32, "a 16-byte id: " & id
doAssert intentIdFor(e & "|safe") != id, "the plain concatenation no longer names the same intent"
doAssert intentIdFor(e, "safe") == id and intentIdFor(e, "threshold") != id
echo "5. the intent id is a 128-bit domain-separated record OK"

echo "signing_path_hardening_test: all OK"
