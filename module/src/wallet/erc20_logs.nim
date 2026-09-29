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
