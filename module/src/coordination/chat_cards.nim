## Which typed cards a chat body may be (exo-3b3.18, audit P4-05).
##
## A message body is opaque: plain text, or a typed card as JSON. The thread draws some cards
## from a body, so a member could post JSON shaped like a card the module makes itself (an
## approval, a receipt, a proposal) and have it drawn as one. Two rules close that:
##
##   reservedCardKind — the kinds only the module's own code posts: a proposal's reference
##     (live.nim), a shared address (coordinate_share_address, from the member's own key or
##     wallet), and the approval / receipt / proposal shapes the module never posts as chat at
##     all. coordinate_post_message refuses a body naming one, by `kind` or `type`.
##   chatCardKind — the kinds the thread may draw from a body: a reference (whose card is
##     drawn from the verified fold, never from the body), an ask for an address, and a shared
##     address, each under its verified author. Anything else is drawn as the text it is.
##
## Pure (std/json): headless-testable (chat_cards_test).

import std/[json, strutils]

const
  ReservedCardKinds* = ["intent-ref", "intent-propose", "intent-approve", "send-receipt",
                        "receipt", "address-share"]
    ## Posted by the module itself, never through coordinate_post_message.
  ChatCardKinds* = ["intent-ref", "address-request", "address-share"]
    ## Drawn as cards from a message body; every other body is text.

proc bodyKind(body: string): string =
  ## The `kind` (or `type`) a JSON object body names, or "" for text, a non-object, or none.
  let b = body.strip()
  if b.len == 0 or b[0] != '{': return ""
  try:
    let j = parseJson(b)
    if j.kind != JObject: return ""
    for key in ["kind", "type"]:
      if j.hasKey(key) and j[key].kind == JString and j[key].getStr().len > 0:
        return j[key].getStr()
  except CatchableError: discard
  ""

proc reservedCardKind*(body: string): string =
  ## The reserved card kind `body` names, or "" when a member may post it as chat.
  let k = bodyKind(body)
  if k in ReservedCardKinds: k else: ""

proc chatCardKind*(body: string): string =
  ## The card kind the thread draws `body` as, or "" when it is drawn as text.
  let k = bodyKind(body)
  if k in ChatCardKinds: k else: ""
