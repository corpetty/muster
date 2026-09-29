## What an ERC-20 payment looks like to the creditor's own read (exo-5ab): the receipt's
## Transfer(address indexed from, address indexed to, uint256 value) logs, decoded, and a
## share matched against them — the token the split names, exactly the share, to payTo.
## Pure: no RPC (the e2e reads real receipts, split_erc20_anvil_e2e).

import std/strutils
import ../src/wallet/erc20_logs

const Tok = "0x5fbdb2315678afecb367f032d93f642f64180aa3"
const Other = "0xe7f1725e7734ce288f8367e1bb143e90bb3f0512"
const Bob = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
const Alice = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
proc word(hex: string): string = "0x" & hex.replace("0x", "").toLowerAscii().align(64, '0')
let transferLog = RawLog(address: Tok,
  topics: @[TransferTopic, word(Bob), word(Alice)],
  data: word("493e0"))                                     # 300000

# ── 1. decode: a Transfer log's token, from, to and value ─────────────────────────
block:
  let ts = tokenTransfers(@[transferLog])
  doAssert ts.len == 1 and ts[0].token == Tok and ts[0].fromHex == Bob and ts[0].toHex == Alice and
           ts[0].valueDec == "300000", $ts
  # an Approval log, a log with too few topics, a log with a short value: not transfers
  let approval = RawLog(address: Tok, topics: @["0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925",
                                               word(Bob), word(Alice)], data: word("1"))
  let short = RawLog(address: Tok, topics: @[TransferTopic, word(Bob)], data: word("1"))
  let bad = RawLog(address: Tok, topics: @[TransferTopic, word(Bob), word(Alice)], data: "0x12")
  doAssert tokenTransfers(@[approval, short, bad]).len == 0
  echo "1. a Transfer log decodes; anything else is not a transfer OK"

# ── 2. match: the split's token, exactly the share, to payTo ──────────────────────
block:
  let ts = tokenTransfers(@[transferLog])
  doAssert matchTokenPayment(ts, Tok, Alice, "300000") == ""
  doAssert matchTokenPayment(ts, Tok.toUpperAscii().replace("0X", "0x"), Alice.toUpperAscii().replace("0X", "0x"), "300000") == "",
           "addresses compare case-insensitively"
  doAssert "token" in matchTokenPayment(ts, Other, Alice, "300000"), "another token never pays the share"
  doAssert "300000" in matchTokenPayment(ts, Tok, Alice, "300001"), "not exactly the share"
  doAssert Bob in matchTokenPayment(ts, Tok, Bob, "300000").toLowerAscii() or
           "pays" in matchTokenPayment(ts, Tok, Bob, "300000"), "paid to someone else"
  doAssert "no Transfer" in matchTokenPayment(@[], Tok, Alice, "300000")
  # several transfers in one transaction (a router, a batch): one exact match is enough
  let two = tokenTransfers(@[RawLog(address: Tok, topics: @[TransferTopic, word(Bob), word(Bob)], data: word("5")),
                            transferLog])
  doAssert matchTokenPayment(two, Tok, Alice, "300000") == ""
  echo "2. a share is paid only by that token, exactly the share, to payTo OK"

# ── 3. what a token says about itself: symbol() and decimals(), ABI-decoded ─────
# Display only (never signed): the card reads "0.3 MTD", and names the token's address
# beside it, because a token names itself.
block:
  proc raw(hex: string): string = hex.toLowerAscii().align(64, '0')   # one 32-byte word, no 0x
  # symbol() -> string "MTD": offset 0x20, length 3, "MTD" right-padded
  let sym = "0x" & raw("20") & raw("3") & "4d5444".alignLeft(64, '0')
  doAssert abiString(sym) == "MTD", abiString(sym)
  doAssert abiUint8("0x" & raw("6")) == 6 and abiUint8(raw("12")) == 18
  # a malformed answer is not a symbol, and an out-of-range decimals is refused
  doAssert abiString("0x1234") == "" and abiString("") == ""
  doAssert abiUint8("0x" & raw("100")) == -1 and abiUint8("0xzz") == -1
  # a long, hostile symbol is cut to a readable length
  let long = "0x" & raw("20") & raw("40") & repeat("41", 64)
  doAssert abiString(long).len <= 16, abiString(long)
  echo "3. symbol() and decimals() decode; a malformed or hostile answer is refused or cut OK"

echo "erc20_logs_test: all OK"
