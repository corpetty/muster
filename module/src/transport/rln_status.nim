## The node's RLN membership, as one connectivity row (exo-eb6.3 R1). Pure: it reads
## the replies muster_module gathers from delivery and the two RLN modules, and says
## what stands and what to do next. Never a false green: an unread reply is "unknown".
##
## Only the logos.test preset runs RLN (delivery v0.3.0). There a node runs without a
## membership, but it sends nothing until one is active: delivery holds each message
## and retries. The RLN modules provision the node's own wallet on the registry's
## zone and register by themselves once its payer holds the price plus a fee reserve,
## so the one step left to a person is funding that payer. Design:
## docs/design/rln-membership.md §6.

import std/[json, strutils]

const
  RlnPreset* = "logos.test"
    ## the one built-in delivery preset with RLN on
  LogosTestRegistry* = "logos:testnet:841312e989c77e3f6f58a5d880a8e25b950b8b5ffba2f39748fa44622c20c893"
    ## that preset's registry: the registration program's config account, CAIP-10
  RlnIdentifierHex* = "5e269b6a19fce081f5808b13442dcbc3522197638dd38df5a28bc4e55236b977"
    ## sha256("rln/logos-delivery/v0.0.1"), delivery's application scope
  RegistryZone* = "209.38.241.182:3240"
    ## the registry's own LEZ zone: not testnet.lez.logos.co, muster's wallet zone
  FundingNative* = "200000000"
    ## what delivery's guide asks a payer to hold: the price plus a fee reserve
    ## (about 1.8e8 at base fee 8, most of it refunded)
  Held = "; this node's messages wait until it is active"
    ## delivery v0.3.0 runs the node without a membership and holds every send,
    ## retrying (rlnState reads "Ready" all the while), so a room that looks fine
    ## locally sends nothing: the row says so

type
  RlnInputs* = object
    preset*: string        ## the delivery config's preset ("" for a hand-written config)
    node*: string          ## delivery rlnState: Disabled | Initializing | Ready | Failed; "" = no node
    nodeMessage*: string   ## the reason, when Failed
    wallet*: JsonNode      ## liblogos_lez_rln_module.wallet_status; nil = unread
    balance*: JsonNode     ## liblogos_lez_rln_module.get_native_balance(payer); nil = unread
    membership*: JsonNode  ## liblogos_rln_module.get_membership_state; nil = unread

proc presetOf*(cfgJson: string): string =
  ## The preset a delivery config names, "" when it names none or is not JSON.
  try:
    let j = parseJson(cfgJson)
    if j.kind == JObject: return j{"preset"}.getStr()
  except CatchableError: discard
  ""

proc parseRlnState*(raw: string): tuple[state, message: string] =
  ## Delivery's rlnState() reply, however it arrives: the state alone ("Ready"), a JSON
  ## object {state, message}, or either inside the lp result envelope {success, value}.
  ## ("", "") when it carries no state (no node yet, an error, nothing).
  var j: JsonNode
  try: j = parseJson(raw)
  except CatchableError:
    return (if raw.len > 0 and raw.allCharsInSet(Letters): (raw, "") else: ("", ""))
  for _ in 0 .. 3:                       # unwrap the envelope and any JSON-in-a-string
    case j.kind
    of JString:
      let s = j.getStr()
      try: j = parseJson(s)
      except CatchableError: return (s, "")
    of JObject:
      if j.hasKey("state"): return (j{"state"}.getStr(), j{"message"}.getStr())
      if j.hasKey("value") and j{"success"}.getBool(true): j = j["value"]
      else: return ("", "")
    else: return ("", "")
  ("", "")

proc decLess(a, b: string): bool =
  ## a < b for canonical decimal strings (u128 balances exceed JSON numbers)
  let x = a.strip(chars = {'0'}, trailing = false)
  let y = b.strip(chars = {'0'}, trailing = false)
  if x.len != y.len: return x.len < y.len
  x < y

proc row(level, detail: string, remedy = ""): JsonNode =
  result = %*{"key": "rln", "name": "RLN membership", "level": level, "detail": detail,
              "source": "room", "introducedBy": []}
  if remedy.len > 0: result["remedy"] = %remedy

proc rlnRow*(i: RlnInputs): JsonNode =
  ## The row, with the payer and balance beside it when known (for a copy button).
  if i.preset != RlnPreset:
    let fleet = (if i.preset.len > 0: i.preset else: "this network")
    return row("ok", "not needed: " & fleet & " runs no RLN")
  # the membership decides when it is known: it is what sending needs
  let state = (if i.membership != nil and i.membership.kind == JObject: i.membership{"state"}.getStr() else: "")
  case state
  of "active":
    result = row("ok", "active: this node's messages carry RLN proofs")
  of "grace_period":
    result = row("warn", "in its grace period: it expires soon",
                 "Register again before it expires (the RLN module does this once its payer is funded).")
  of "pending":
    result = row("warn", "registering: usually 1–3 minutes once the funds land" & Held)
  of "expired", "erased", "slashed", "failed":
    result = row("down", "membership " & state & ": this node cannot send on " & RlnPreset,
                 "Fund the payer again; the RLN module registers a new membership by itself.")
  else: discard
  if result != nil:
    if i.wallet != nil and i.wallet.kind == JObject and i.wallet{"payer"}.getStr().len > 0:
      result["payer"] = %i.wallet["payer"].getStr()
    return
  if i.node == "Failed":
    return row("down", "RLN failed to start" & (if i.nodeMessage.len > 0: ": " & i.nodeMessage else: ""))
  if i.node.len == 0 or i.node == "Disabled":
    return row("unknown", "starts when you join a room on " & RlnPreset)
  if i.wallet == nil or i.wallet.kind != JObject:
    return row("unknown", "the RLN wallet has not answered yet")
  let ws = i.wallet{"state"}.getStr()
  if ws == "failed":
    return row("down", "the RLN wallet failed: " & i.wallet{"detail"}.getStr())
  let payer = i.wallet{"payer"}.getStr()
  if ws != "ready" or payer.len == 0:
    return row("unknown", "setting up this node's RLN wallet on the registry's zone")
  let bal = (if i.balance != nil and i.balance.kind == JObject: i.balance{"balance"}.getStr() else: "")
  if bal.len == 0:
    result = row("unknown", "checking what the payer holds")
  elif decLess(bal, FundingNative):
    result = row("warn", "awaiting funding: the payer holds " & bal & " native LEZ" & Held,
                 "Send at least " & FundingNative & " native LEZ to " & payer & " on the RLN registry's zone (" &
                 RegistryZone & "). Registration then runs by itself.")
  else:
    result = row("warn", "funded (" & bal & " native LEZ): registration is under way" & Held)
  result["payer"] = %payer
  if bal.len > 0: result["balance"] = %bal
