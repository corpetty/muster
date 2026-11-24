## A chat body never becomes a typed card the module makes itself (exo-3b3.18, audit P4-05).
## coordinate_post_message carries whatever a member types; a body that is JSON naming a card
## kind the module publishes on its own path (a proposal reference, an approval, a receipt,
## a shared address) is refused there, so only the module's own code posts those. An ask for
## an address is the UI's to post, and stays allowed; so does plain text, and JSON that names
## no kind. Pure: no keys, no transport.

import ../src/coordination/chat_cards

for k in ["intent-ref", "intent-propose", "intent-approve", "send-receipt", "receipt",
          "address-share"]:
  doAssert reservedCardKind("""{"kind":"""" & k & """","x":1}""") == k, k
  doAssert reservedCardKind("""{"type":"""" & k & """"}""") == k, "by type: " & k
  doAssert reservedCardKind("""  {"kind": """" & k & """"}  """) == k, "with space: " & k
echo "1. the module's own card kinds are reserved, by kind or type OK"

doAssert reservedCardKind("hello") == ""
doAssert reservedCardKind("""{"kind":"address-request","purpose":"Pay someone"}""") == ""
doAssert reservedCardKind("""{"note":"no kind"}""") == ""
doAssert reservedCardKind("""["intent-ref"]""") == ""
doAssert reservedCardKind("""{"kind":""") == "", "malformed JSON is text"
doAssert reservedCardKind("""{"kind":42}""") == ""
echo "2. text, an ask, kindless and malformed JSON pass OK"

doAssert chatCardKind("""{"kind":"intent-ref","intentId":"0x1"}""") == "intent-ref"
doAssert chatCardKind("""{"kind":"address-request"}""") == "address-request"
doAssert chatCardKind("""{"kind":"address-share","address":"0xabc"}""") == "address-share"
for k in ["intent-propose", "intent-approve", "send-receipt", "receipt", "transfer", "anything"]:
  doAssert chatCardKind("""{"kind":"""" & k & """"}""") == "", "a chat body never renders as " & k
echo "3. only a reference, an ask and a shared address render from chat as cards OK"

echo "chat_cards_test: all OK"
