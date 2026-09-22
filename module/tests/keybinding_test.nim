## per-key F-14 binding on a keyed contribution (exo-45e K5). Two halves:
##
## A. the keystore primitive — `bindingForKey(ref)` binds the CHOSEN authorization key
##    to our admitted encryption identity: the binding's recoverable signer is THAT key's
##    address (not the primary), while the enc identity vouched for is the same one that
##    joined. So one instance holding several owner keys can prove EACH belongs to the
##    room member (F-14 / F-9). Links secp + sodium.
## B. the log fold — a published `keyBindingEvent` folds once per (intent, key) idempotently
##    (invariant 4), is classed peer-message in provenance (named/anon per driver, invariant
##    9), and discloses only the in-room key-binding link in the flow view (nothing leaves
##    the room until submit). Pure Nim (stub driver).

import std/[strutils, algorithm]
import ../src/dcbor/dcbor
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/secp256k1
import ../src/drivers/driver
import ../src/coordination/intents
import ../src/coordination/flow

proc bytesOf(hex: string): seq[byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] in {'x','X'}): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc secret(hex: string): array[32, byte] =
  let b = bytesOf(hex); (for i in 0 ..< 32: result[i] = b[i])
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

const KEY0 = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # → 0xf39F…2266
const KEY1 = "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"  # → 0x7099…79C8

# One instance that holds BOTH owner keys but has ONE admitted encryption identity.
let ks = newInMemoryKeystore(secret(KEY0), seed(1))
let ref1 = ks.addKey(secret(KEY1), seed(2))
let ref0 = refOf(ks.address())
let owner0 = ks.address()
let owner1 = addressOf(secret(KEY1))
let ctx = LinkContext(account: "0xROOM", slot: "0", expiry: 2_000_000_000'u64)
const now = 1'u64

# ── A1. bindingForKey(ref) binds the CHOSEN key — its signer is that key's address ─────
block:
  let st0 = ks.bindingForKey(ref0, ctx)
  let st1 = ks.bindingForKey(ref1, ctx)
  doAssert bindingSigner(st0, now) == owner0, "primary ref binds the primary key"
  doAssert bindingSigner(st1, now) == owner1, "the extra ref binds the EXTRA key (the K5 fix)"
  doAssert bindingSigner(st0, now) != bindingSigner(st1, now)
  echo "A1. bindingForKey(ref) binds the chosen key — signer is that key's address OK"

# ── A2. every keyed binding vouches for the SAME admitted encryption identity ──────────
block:
  let stP = ks.bindingFor(ctx)                 # the join/primary path — our admitted enc identity
  let st1 = ks.bindingForKey(ref1, ctx)
  # the first 64 wire bytes are the encryption identity being vouched for (encodeLink).
  doAssert encodeLink(st1)[0 ..< 64] == encodeLink(stP)[0 ..< 64],
    "the extra key vouches for our admitted (primary) enc identity — the membership identity"
  # so it links the extra owner key to the member: it binds against owner1, not owner0.
  doAssert bindingBinds(st1, @[owner1], now), "binds against the extra key's own address"
  doAssert not bindingBinds(st1, @[owner0], now), "does not bind against a different owner"
  echo "A2. a keyed binding vouches for the admitted enc identity, bound to the chosen key OK"

# ── A3. an unknown ref is refused; the wire form round-trips the signer ────────────────
block:
  var refused = false
  try: discard ks.bindingForKey("0xnope", ctx)
  except KeystoreError: refused = true
  doAssert refused, "bindingForKey on an unknown ref refuses"
  let st1 = ks.bindingForKey(ref1, ctx)
  doAssert bindingSigner(decodeLink(encodeLink(st1)), now) == owner1, "encodeLink round-trips the signer"
  echo "A3. an unknown ref is refused; encodeLink/decodeLink preserve the signer OK"

# ── B. the log fold: a published binding folds, is classed, discloses in-room ──────────
let effectJson = """{"to":"0xabc","value":5}"""
let id = intentIdFor(effectJson)
let named: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 2, membership = mmNamed, verifyResult = true)
let anon: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 2, membership = mmAnonymous, verifyResult = true)
let linkHex = toHex(encodeLink(ks.bindingForKey(ref1, ctx)))

# ── B1. a binding folds once per (intent, key); reorder + duplicate are idempotent ─────
block:
  let b1 = keyBindingEvent(id, "0xOWNER1", linkHex)
  var events = @[proposeEvent(id, effectJson), b1, b1,
                 keyBindingEvent(id, "0xOWNER0", linkHex)]
  let binds = reduceBindings(events, id)
  doAssert binds.len == 2, "one per (intent, key), duplicate folded: " & $binds.len
  var who: seq[string]
  for b in binds: (doAssert b.linkHex == linkHex; who.add b.contributor)
  who.sort()
  doAssert who == @["0xOWNER0", "0xOWNER1"]
  var reordered = @[events[3], events[1], events[0], events[2]]
  doAssert $reduceBindings(reordered, id) == $reduceBindings(events, id), "reorder → identical (inv 4)"
  echo "B1. a binding folds once per (intent, key); reorder + dup idempotent (inv 4) OK"

# ── B2. provenance: a binding is peer-message, named under a named driver ──────────────
block:
  let events = @[proposeEvent(id, effectJson), keyBindingEvent(id, "0xOWNER1", linkHex)]
  var found = false
  for it in logProvenance(events, named):
    if it.kind == "binding":
      found = true
      doAssert it.cls == icPeerMessage, "a binding is peer-shared room data"
      doAssert it.account == "0xOWNER1", "named driver names the key"
      doAssert it.guarantee.contains("admitted") and it.guarantee.contains("F-14"),
        "guarantee is honest: proves an admitted member, not merely a valid owner: " & it.guarantee
  doAssert found, "the binding appears in provenance"
  # anonymous driver names nobody (invariant 9).
  for it in logProvenance(events, anon):
    if it.kind == "binding": doAssert it.account == "", "anonymous driver: the binding names nobody"
  echo "B2. provenance: a binding is peer-message, named/anon per driver, guarantee honest OK"

# ── B3. flow: a binding discloses the in-room key-binding link; nothing leaves the room ─
block:
  let events = @[policyDeclEvent(id, "stub"), proposeEvent(id, effectJson),
                 keyBindingEvent(id, "0xOWNER1", linkHex)]
  let rows = reduceFlow(events, named, @["me"])
  var sawRoomLink, sawOutsideAtBinding = false
  for r in rows:
    if r.kind == "binding" and r.field == "key-binding" and r.to == obRoomMember: sawRoomLink = true
    if r.kind == "binding" and r.to == obChainObserver: sawOutsideAtBinding = true
  doAssert sawRoomLink, "the key-binding link is disclosed to the room at the binding"
  doAssert not sawOutsideAtBinding, "nothing leaves the room at the binding — outside rows wait for submit"
  echo "B3. flow: a binding discloses the in-room key-binding link; outside rows wait for submit OK"

echo "keybinding_test: all OK"
