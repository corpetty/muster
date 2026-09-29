## An ERC-20 payment as the creditor's own read sees it (exo-5ab): the receipt's
## Transfer(address indexed from, address indexed to, uint256 value) logs, decoded, and a
## share matched against them. Pure — the RPC that fetches the receipt is evm_rpc's.

import std/strutils
import stint

const TransferTopic* = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  ## keccak256("Transfer(address,address,uint256)")

type
  RawLog* = object
    ## A receipt log as hex text: the emitting contract, its topics, its data.
    address*: string
    topics*: seq[string]
    data*: string

  TokenTransfer* = object
    token*, fromHex*, toHex*: string   ## lowercase 0x addresses
    valueDec*: string                  ## the amount in the token's base units, decimal

proc bare(s: string): string =
  result = s.strip().toLowerAscii()
  if result.startsWith("0x"): result = result[2 .. ^1]

proc isHex(s: string): bool = s.len > 0 and s.allCharsInSet(HexDigits)

proc tokenTransfers*(logs: seq[RawLog]): seq[TokenTransfer] =
  ## Every log that is an ERC-20 Transfer: three topics (the event, from, to) and a 32-byte
  ## value. An Approval, an anonymous event or a malformed log is not a transfer.
  for l in logs:
    if l.topics.len != 3 or "0x" & bare(l.topics[0]) != TransferTopic: continue
    let f = bare(l.topics[1])
    let t = bare(l.topics[2])
    let v = bare(l.data)
    if f.len != 64 or t.len != 64 or v.len != 64 or not (isHex(f) and isHex(t) and isHex(v)): continue
    result.add TokenTransfer(token: "0x" & bare(l.address), fromHex: "0x" & f[24 .. ^1],
                             toHex: "0x" & t[24 .. ^1], valueDec: $UInt256.fromHex(v))

proc matchTokenPayment*(ts: seq[TokenTransfer], token, to, amount: string): string =
  ## "" when one of `ts` is `token` paying exactly `amount` to `to`; else why not, named.
  ## Who sent it is not asked — as with ETH, a share may be paid from any address.
  if ts.len == 0: return "the transaction emitted no Transfer of any token"
  let tok = "0x" & bare(token)
  let dst = "0x" & bare(to)
  var same: seq[TokenTransfer]
  for t in ts:
    if t.token == tok: same.add t
  if same.len == 0: return "it moves another token (" & ts[0].token & "), not the split's " & tok
  for t in same:
    if t.toHex == dst and t.valueDec == amount: return ""
  for t in same:
    if t.toHex == dst:
      return "it pays " & t.valueDec & " of " & tok & " to " & dst & "; the share is " & amount
  "it pays " & same[0].toHex & ", not " & dst

# ── what a token says about itself (display only — never signed) ─────────────────
proc hexBytes(h: string): seq[byte] =
  let s = bare(h)
  if s.len mod 2 != 0 or not isHex(s): return @[]
  for i in countup(0, s.len - 2, 2): result.add byte(parseHexInt(s[i .. i + 1]))

proc wordAt(b: seq[byte], at: int): int =
  ## A 32-byte big-endian word as an int, or -1 when out of range / too large to be an offset.
  if at < 0 or at + 32 > b.len: return -1
  for i in at ..< at + 28:
    if b[i] != 0: return -1
  (int(b[at + 28]) shl 24) or (int(b[at + 29]) shl 16) or (int(b[at + 30]) shl 8) or int(b[at + 31])

proc abiString*(hex: string): string =
  ## symbol() / name() decoded: an ABI string (offset, length, bytes), or — older tokens —
  ## a bytes32. Printable ASCII only, cut to 16 characters: a token names itself, so what it
  ## says is shown briefly and beside its address, never trusted. "" when malformed.
  let b = hexBytes(hex)
  var raw: seq[byte]
  if b.len == 32:
    for x in b:
      if x == 0: break
      raw.add x
  else:
    let off = wordAt(b, 0)
    if off < 0: return ""
    let n = wordAt(b, off)
    if n < 0 or off + 32 + n > b.len: return ""
    raw = b[off + 32 ..< off + 32 + n]
  for x in raw:
    if x >= 0x20 and x < 0x7f: result.add char(x)
  if result.len > 16: result = result[0 ..< 16]

proc abiUint8*(hex: string): int =
  ## decimals() decoded, or -1 when malformed or beyond 36 (no real token needs more, and
  ## a display with 70 decimals is a hostile one).
  let b = hexBytes(hex)
  if b.len != 32: return -1
  let v = wordAt(b, 0)
  if v < 0 or v > 36: -1 else: v
