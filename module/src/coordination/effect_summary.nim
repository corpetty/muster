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
                    ## btc-spend | lez-transfer | lez-call | lez-proposal | unknown
    amount*: string ## the decimal amount it moves, in `unit`; "" when it names none
    unit*: string   ## wei | sat | token units | ""
    to*: string     ## the payee or target, in full; "" when none
    text*: string   ## one plain line: what the room is asked to do

proc short(s: string): string =
  if s.len > 12: s[0 ..< 6] & "…" & s[^4 .. ^1] else: s

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

proc effectSummary*(effectJson: string): EffectSummary =
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
