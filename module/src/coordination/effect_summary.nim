## What an intent's effect does, in plain words (exo-59c) — ONE reading of the effect
## JSON, which the card and the room history both use, so they cannot tell two stories.
##
## It reads the shapes the drivers propose: a Safe transaction (a payment, a contract
## call, a DELEGATECALL), a room statement, a policy grant, a module action, a Bitcoin
## spend, a LEZ call and a LEZ multisig proposal. A LEZ transfer is recognized from the
## instruction's shape (the token program's Transfer: variant 0, a u128 amount, two
## accounts) — the same inference the card always drew, now in one place. Anything else
## is named for what it is, never dressed up as a payment.

import std/[json, strutils]
import stint
import ../bitcoin/[bech32, network, tx]

type
  EffectSummary* = object
    kind*: string   ## payment | contract-call | delegatecall | statement | policy | action |
                    ## btc-spend | lez-transfer | lez-call | lez-proposal | split | unknown
    amount*: string ## the decimal amount it moves, in `unit`; "" when it names none
    unit*: string   ## wei | sat | token units | ""
    to*: string     ## the payee or target, in full; "" when none
    text*: string   ## one plain line: what the room is asked to do

proc short(s: string): string =
  if s.len > 12: s[0 ..< 6] & "…" & s[^4 .. ^1] else: s

proc inDecimals(raw: string, decimals: int): string =
  ## Base units as a decimal in the asset's own decimals, by string (never a float):
  ## "600000000000000000", 18 -> "0.6"; "100", 9 -> "0.0000001".
  var r = raw.strip()
  if r.len == 0 or not r.allCharsInSet({'0' .. '9'}): return raw
  while r.len <= decimals: r = "0" & r
  var whole = r[0 ..< r.len - decimals]
  var frac = r[r.len - decimals .. ^1]
  while frac.len > 0 and frac[^1] == '0': frac.setLen(frac.len - 1)
  while whole.len > 1 and whole[0] == '0': whole = whole[1 .. ^1]
  if frac.len > 0: whole & "." & frac else: whole

proc numText(n: JsonNode): string =
  ## A JSON number or numeric string, as decimal text.
  if n.isNil: return "0"
  case n.kind
  of JString: n.getStr()
  of JInt: $n.getBiggestInt()
  else: $n

proc u128Words(words: JsonNode, first: int): string =
  ## A little-endian u128 from four u32 instruction words starting at `first`.
  var a = 0.u256
  for i in countdown(first + 3, first):
    a = (a shl 32) + words[i].getBiggestInt().uint64.u256
  $a

proc isTokenTransfer(ins, accts: JsonNode): bool =
  not ins.isNil and ins.kind == JArray and ins.len == 5 and ins[0].getBiggestInt() == 0 and
    not accts.isNil and accts.kind == JArray and accts.len == 2

proc argCount(args: JsonNode): int =
  if args.isNil: return 0
  if args.kind == JArray: return args.len
  if args.kind == JString:
    try:
      let a = parseJson(args.getStr())
      if a.kind == JArray: return a.len
    except CatchableError: discard
  0

proc btcSummary(j: JsonNode): EffectSummary =
  ## The payment is every output that does not pay back to the account being spent
  ## from (the inputs' scriptPubKey); the rest is change.
  result = EffectSummary(kind: "btc-spend", unit: "sat")
  var accountSpk = ""
  if j.hasKey("inputs") and j["inputs"].len > 0:
    accountSpk = j["inputs"][0]{"scriptPubKey"}.getStr().toLowerAscii()
  var total: uint64
  var payees: seq[string]
  for o in j{"outputs"}.getElems():
    let a = o{"address"}.getStr()
    var spk = ""
    try: spk = toHex(scriptPubKeyOfAddress(hrpOfAddress(a), a)).toLowerAscii()
    except CatchableError: discard
    if spk.len > 0 and spk == accountSpk: continue          # change back to the account
    total += uint64(o{"value"}.getBiggestInt())
    payees.add a
  let fee = (if j.hasKey("fee"): "  ·  fee " & numText(j["fee"]) & " sat" else: "")
  if payees.len == 0:
    result.text = "a Bitcoin spend back to the account" & fee
    return
  result.amount = $total
  result.to = payees[0]
  result.text = "a Bitcoin payment: " & $total & " sat → " & short(payees[0]) &
                (if payees.len > 1: " and " & $(payees.len - 1) & " more" else: "") & fee

proc effectSummary*(effectJson: string, label: proc (who: string): string = nil,
                    token: proc (asset: string): tuple[symbol: string, decimals: int] = nil): EffectSummary =
  ## `label` names a person the effect carries (a split's creditor) the way the card
  ## does — "you", an alias (exo-221); without one, a short id. `token` says what an ERC-20
  ## asset calls itself and its decimals (display only, exo-5ab); without it, base units.
  if effectJson.len == 0: return EffectSummary(kind: "unknown", text: "a proposal")
  var j: JsonNode
  try: j = parseJson(effectJson)
  except CatchableError: return EffectSummary(kind: "unknown", text: "a proposal")
  if j.kind != JObject: return EffectSummary(kind: "unknown", text: "a proposal")
  let kind = j{"effect"}.getStr()
  case kind
  of "statement":
    return EffectSummary(kind: "statement", text: "a statement: “" & j{"text"}.getStr() & "”")
  of "add-driver":
    return EffectSummary(kind: "policy", text: "a new policy: " & j{"kind"}.getStr("?"))
  of "invoke":
    let call = j{"module"}.getStr() & "." & j{"method"}.getStr()
    let n = argCount(j{"args"})
    return EffectSummary(kind: "action", to: call,
                         text: "an action: " & call & " (" & $n & (if n == 1: " arg)" else: " args)"))
  of "btc-spend":
    return btcSummary(j)
  of "settle-up":
    # several splits netted (exo-3c6): how many payments settle how many shares, and from
    # how many splits — never dressed up as one payment
    let n = j{"transfers"}.getElems().len
    let m = j{"covers"}.getElems().len
    var splits: seq[string]
    for c in j{"covers"}.getElems():
      if c{"intent"}.getStr() notin splits: splits.add c{"intent"}.getStr()
    let memo = j{"memo"}.getStr()
    return EffectSummary(kind: "settle-up", unit: j{"asset"}.getStr(),
      text: "a settle-up" & (if memo.len > 0: " — " & memo else: "") & ": " &
            (if n == 0: "no payment settles " elif n == 1: "1 payment settles " else: $n & " payments settle ") &
            $m & " shares from " & $splits.len & (if splits.len == 1: " split" else: " splits"))
  of "split":
    # who owes the creditor what (exo-a90.3) — never dressed up as one payment
    let n = j{"shares"}.getElems().len
    let asset = j{"asset"}.getStr()
    let unit = (if asset == "ETH": "wei" elif asset == "BTC": "sat" else: asset)
    let total = numText(j{"total"})
    let memo = j{"memo"}.getStr()
    # the words read in the asset's own decimals (ETH 18, LEZ 9, BTC 8); .amount/.unit stay raw
    let tokenAddr = (if asset.startsWith("erc20:"): asset[6 .. ^1] else: "")
    let t = (if tokenAddr.len > 0 and token != nil: token(asset) else: ("", -1))
    let shown =
      if tokenAddr.len == 0: inDecimals(total, (if asset == "LEZ": 9 elif asset == "BTC": 8 else: 18)) & " " & asset
      elif t[1] >= 0: inDecimals(total, t[1]) & " " & (if t[0].len > 0: t[0] else: "units")
      else: total & " base units of token " & short(tokenAddr)
    # a bill in fiat (exo-3a4): the bill in its currency, then what it comes to in the asset
    let q = j{"quote"}
    let billed =
      if q != nil and q.kind == JObject and q{"currency"}.getStr().len > 0:
        var fd = 2
        try: fd = parseInt(q{"fiatDecimals"}.getStr("2"))
        except ValueError: discard
        var r = q{"fiatTotal"}.getStr()
        while r.len <= fd: r = "0" & r
        let fiat = (if fd == 0: r else: r[0 ..< r.len - fd] & "." & r[r.len - fd .. ^1])
        fiat & " " & q{"currency"}.getStr() & " (" & shown & ")"
      else: shown
    let creditor = j{"creditor"}.getStr()
    return EffectSummary(kind: "split", amount: total, unit: unit, to: j{"payTo"}.getStr(),
      text: "a split" & (if memo.len > 0: " — " & memo else: "") & ": " & billed & ", " &
            $n & (if n == 1: " person owes " else: " people owe ") &
            (if label != nil: label(creditor) else: short(creditor)))
  else: discard
  if j.hasKey("program") and j.hasKey("instruction"):         # a LEZ call
    if isTokenTransfer(j["instruction"], j{"accounts"}):
      let amt = u128Words(j["instruction"], 1)
      let to = j["accounts"][1].getStr()
      return EffectSummary(kind: "lez-transfer", amount: amt, unit: "token units", to: to,
                           text: "a LEZ transfer: " & amt & " token units → " & short(to))
    return EffectSummary(kind: "lez-call", to: j["program"].getStr(),
                         text: "a LEZ call to " & short(j["program"].getStr()))
  if j.hasKey("index") and j.hasKey("target"):                 # a LEZ multisig proposal
    let idx = numText(j["index"])
    let ins = j{"instruction"}
    let accts = j{"accounts"}
    if isTokenTransfer(ins, accts):
      let amt = u128Words(ins, 1)
      let to = accts[1].getStr()
      return EffectSummary(kind: "lez-proposal", amount: amt, unit: "token units", to: to,
        text: "on-chain proposal #" & idx & ": transfer " & amt & " token units from the vault to " & short(to))
    if not ins.isNil and ins.kind == JArray and ins.len == 1 and ins[0].getBiggestInt() == 3 and
       not accts.isNil and accts.len == 2:
      return EffectSummary(kind: "lez-proposal",
        text: "on-chain proposal #" & idx & ": set up the vault to hold token " & short(accts[0].getStr()))
    return EffectSummary(kind: "lez-proposal", to: j["target"].getStr(),
      text: "on-chain proposal #" & idx & ": call " & short(j["target"].getStr()))
  if j.hasKey("to"):                                           # a Safe transaction
    let to = j["to"].getStr()
    let value = numText(j{"value"})
    let data = j{"data"}.getStr()
    let hasData = data.len > 0 and data != "0x"
    if j{"operation"}.getBiggestInt(0) == 1:
      return EffectSummary(kind: "delegatecall", to: to,
        text: "a DELEGATECALL to " & short(to) & " — it runs that code as the Safe itself")
    if hasData:
      return EffectSummary(kind: "contract-call", to: to,
        amount: (if value != "0": value else: ""), unit: (if value != "0": "wei" else: ""),
        text: "a contract call to " & short(to) & (if value != "0": ", sending " & value & " wei" else: ""))
    return EffectSummary(kind: "payment", amount: value, unit: "wei", to: to,
                         text: "a payment: " & value & " wei → " & short(to))
  EffectSummary(kind: "unknown", text: "a proposal" & (if kind.len > 0: " (" & kind & ")" else: ""))
