## exo-59c — the card and the room history say what an intent does, in the words of its
## own family, and name who approved.
##
## Reading the client end to end for the tour runbook found the room telling the wrong
## story about everything that isn't a Safe payment:
##   - a Bitcoin spend, a LEZ call or a module action was summarized as "a payment: 0 → "
##     (the history read `value`/`to`, which only a Safe transfer carries), and the card
##     showed no amount at all;
##   - every submit read "the Safe execTransaction was sent through the RPC" and every
##     final "the payment landed" — for a Bitcoin broadcast, a LEZ Execute, a module call;
##   - the approval slots never named anyone, and the client could not tell whether YOU
##     had approved, so Approve stayed on the card after you used it.
##
## One reading of an effect (effect_summary.nim) now serves both the card and the
## history, so they cannot disagree; the submit/final lines come from the family's
## settlement; approvers are named from the address book; and "approved by me" is read
## from the log + this member's keys, never assumed. Held over EVERY generated
## (kind, variant), so a new family meets it too. Needs the full closure (run-suite.sh).

import std/[json, strutils]
import ../tools/action_corpus
import ../src/log/log
import ../src/drivers/driver
import ../src/crypto/curve25519
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/coordination/intents
import ../src/coordination/intent_events
import ../src/coordination/attest
import ../src/coordination/contacts
import ../src/coordination/effect_summary

proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc eff(key: string): string = proposedEffectJson(key)
proc proposeTitle(kind, variant: string): string =
  let d = fixtureDriver(kind)
  let dfor: DriverFor = proc(k: string): Driver = d
  let ej = eff(kind & "/" & variant)
  let id = intentIdFor(ej, kind)
  for a in reduceActivity(@[policyDeclEvent(id, kind), proposeEvent(id, ej)], dfor):
    if a.kind == "propose": return a.title

# ── 1. no family is summarized as a zero payment; each says what it moves ──────────
block:
  for (kind, variant) in Variants:
    let t = proposeTitle(kind, variant)
    doAssert t.len > 0, kind & "/" & variant & ": no proposal line"
    doAssert "a payment: 0 → " notin t, kind & "/" & variant & " reads as a zero payment: " & t
  let v = $parseJson(eff("safe/transfer"))["value"].getBiggestInt()
  doAssert ("a payment: " & v & " wei → 0x") in proposeTitle("safe", "transfer"), proposeTitle("safe", "transfer")
  doAssert "contract call" in proposeTitle("safe", "contract-call"), proposeTitle("safe", "contract-call")
  doAssert "DELEGATECALL" in proposeTitle("safe", "delegatecall"), proposeTitle("safe", "delegatecall")
  doAssert "an action: delivery_module.send" in proposeTitle("invoke", "module-call"), proposeTitle("invoke", "module-call")
  for k in ["btc-p2wsh", "btc-tapscript", "btc-frost"]:
    let t = proposeTitle(k, "spend")
    doAssert "a Bitcoin payment: " in t and " sat → bcrt1" in t, k & ": " & t
  doAssert "a LEZ transfer: 200 token units → " in proposeTitle("lez-frost", "transfer"), proposeTitle("lez-frost", "transfer")
  doAssert "transfer 200 token units from the vault to " in proposeTitle("lez-multisig", "transfer"),
    proposeTitle("lez-multisig", "transfer")
  doAssert "set up the vault" in proposeTitle("lez-multisig", "vault-init"), proposeTitle("lez-multisig", "vault-init")
  echo "1. every family's proposal says what it moves, never 'a payment: 0 →' OK"

# ── 2. the card reads the same summary: amount, unit and payee; change is not a payment ──
block:
  let btc = effectSummary(eff("btc-frost/spend"))
  let outs = parseJson(eff("btc-frost/spend"))["outputs"]
  doAssert btc.kind == "btc-spend" and btc.unit == "sat"
  doAssert btc.amount == $outs[0]["value"].getInt() and btc.to == outs[0]["address"].getStr(),
    "the payment output, not the change back to the account: " & btc.amount & " → " & btc.to
  let lez = effectSummary(eff("lez-frost/transfer"))
  doAssert lez.kind == "lez-transfer" and lez.amount == "200" and lez.unit == "token units" and lez.to.len == 64
  let safe = effectSummary(eff("safe/transfer"))
  doAssert safe.kind == "payment" and safe.unit == "wei" and safe.to.startsWith("0x")
  doAssert effectSummary(eff("threshold/statement")).kind == "statement"
  doAssert effectSummary("").kind == "unknown"
  echo "2. the card's summary: the payment output, its unit and payee; change excluded OK"

# ── 3. submit and final are told in the words of the family that settles ───────────
block:
  proc lines(kind, variant: string): tuple[submit, final: string] =
    let d = fixtureDriver(kind)
    let dfor: DriverFor = proc(k: string): Driver = d
    let ej = eff(kind & "/" & variant)
    let id = intentIdFor(ej, kind)
    let ev = @[policyDeclEvent(id, kind), proposeEvent(id, ej), submitEvent(id, chainRef = "0xabc"), finalEvent(id)]
    for a in reduceActivity(ev, dfor):
      if a.kind == "submit": result.submit = a.title & " — " & a.detail
      if a.kind == "settled": result.final = a.title & " — " & a.detail
  let safe = lines("safe", "transfer")
  doAssert "execTransaction" in safe.submit, safe.submit
  for k in ["btc-p2wsh", "btc-frost"]:
    let b = lines(k, "spend")
    doAssert "Bitcoin" in b.submit and "Safe" notin b.submit and "execTransaction" notin b.submit, k & ": " & b.submit
    doAssert "Safe" notin b.final and "payment landed" notin b.final, k & ": " & b.final
  for (k, v) in [("lez-multisig", "transfer"), ("lez-frost", "transfer")]:
    let l = lines(k, v)
    doAssert "LEZ" in l.submit and "Safe" notin l.submit, k & ": " & l.submit
  let inv = lines("invoke", "module-call")
  doAssert "action" in inv.submit.toLowerAscii() and "Safe" notin inv.submit, inv.submit
  doAssert "action" in inv.final.toLowerAscii() and "payment" notin inv.final, inv.final
  echo "3. submit and final lines follow the family's settlement OK"

# ── 4. approvers are named; decliners too ─────────────────────────────────────────
block:
  let book = newContactBook("")
  var s2: array[32, byte]
  for i in 0 ..< 32: s2[i] = 2
  let bobHex = hx(encFromSeed(s2).identity().toBytes())
  book.add(bobHex, "Bob", "0x70997970c51812dc3a010c7d01b50e0d17dc79c8")
  doAssert book.nameFor(bobHex) == "Bob", "a 64-byte identity"
  doAssert book.nameFor("ed:" & bobHex[0 ..< 64]) == "Bob", "an Ed25519 contributor name"
  doAssert book.nameFor("frost:" & bobHex[0 ..< 64]) == "Bob", "a room-FROST contributor name"
  doAssert book.nameFor("0x70997970C51812dc3A010C7d01b50e0d17dc79C8") == "Bob", "a secp address, any case"
  doAssert book.nameFor("0x0000000000000000000000000000000000000001") == "", "an unknown address stays unnamed"
  echo "4. contributors named from the address book, by identity, key or address OK"

# ── 5. "approved by me" comes from the log + my keys, never assumed ───────────────
block:
  proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let mine = newInMemoryKeystore(seed(0x31), seed(0x41))
  let other = newInMemoryKeystore(seed(0x32), seed(0x42))
  let me = mine.encIdentity()
  let names = myContributorNames(mine)
  let mineWho = "0x" & hx(mine.address())
  let theirsWho = "0x" & hx(other.address())
  doAssert mineWho in names, "my secp address, as the Safe/EIP-191 drivers name me"
  doAssert ("ed:" & hx(me.ed)) in names and ("frost:" & hx(me.ed)) in names, "my Ed25519 key, as the room drivers name me"
  doAssert theirsWho notin names
  let id = "0x1234"
  let ctx = LinkContext(account: "room", slot: "0", expiry: high(uint64))
  # an approval published under my own address is mine
  doAssert approvedByMe(@[], id, @[mineWho], me, names)
  # someone else's is not
  doAssert not approvedByMe(@[], id, @[theirsWho], me, names)
  # A key that is none of my names counts as mine only when the log carries a binding
  # that key itself signed, naming MY identity (an in-app approval with another held key).
  let spare = newInMemoryKeystore(seed(0x33), seed(0x41))      # another secp key, MY encryption seed
  doAssert spare.encIdentity() == me
  let spareWho = "0x" & hx(spare.address())
  doAssert spareWho notin names
  let bound = keyBindingEvent(id, spareWho, "0x" & hx(encodeLink(spare.bindingFor(ctx))))
  doAssert approvedByMe(@[bound], id, @[spareWho], me, names), "a key the log binds to me"
  # someone else binding their own key to someone else's identity: not mine
  let boundToOther = keyBindingEvent(id, theirsWho, "0x" & hx(encodeLink(other.bindingFor(ctx))))
  doAssert not approvedByMe(@[boundToOther], id, @[theirsWho], me, names)
  # a binding naming me but filed under a different approver's name: the signer is not
  # that approver, so it proves nothing about theirs
  let misfiled = keyBindingEvent(id, theirsWho, "0x" & hx(encodeLink(spare.bindingFor(ctx))))
  doAssert not approvedByMe(@[misfiled], id, @[theirsWho], me, names),
    "a binding counts only when its own signer is the approver it is filed under"
  echo "5. approved-by-me: my own names, or a binding to my identity in the log OK"

echo "card_words_test: all OK"
