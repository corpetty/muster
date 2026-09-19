## Invite primitives (exo-3f0/A): a room invite is a payload SEALED to the recipient's
## X25519 and dropped on their inbox topic (derived deterministically from their chat id).
## This tests the two properties the invite path depends on:
##   1. the inbox topic is a deterministic function of the chat id (a sender must derive
##      the same one the recipient listens on, with no prior contact);
##   2. an invite sealed to a recipient opens for them and for no one else (sealed box).
## Mirrors muster_module's `inboxTopicFor` derivation as a golden anchor.

import std/strutils
import ../src/crypto/curve25519
import ../src/hashing/sha256

proc encFrom(n: byte): EncKeys =
  var seed: array[32, byte]
  for i in 0 ..< 32: seed[i] = n
  encFromSeed(seed)

proc toContentTopic(t: string): string =
  var name = t.strip(chars = {'/'}).replace("/", ".")
  if name.len == 0: name = "room"
  "/muster/1/" & name & "/proto"

proc inboxTopicFor(chatIdHex: string): string =
  var id = chatIdHex.strip()
  if id.len >= 2 and id[0] == '0' and (id[1] == 'x' or id[1] == 'X'): id = id[2 .. ^1]
  id = id.toLowerAscii()
  var buf: seq[byte] = @[]
  for c in "muster-inbox-v1": buf.add byte(c)
  for c in id: buf.add byte(c)
  let h = sha256(buf)
  const d = "0123456789abcdef"
  var hx = ""
  for i in 0 ..< 8: (hx.add d[int(h[i] shr 4)]; hx.add d[int(h[i] and 0x0f)])
  toContentTopic("muster.inbox." & hx)

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let alice = encFrom(1)
let bob = encFrom(2)
let bobChat = toHex(bob.identity().toBytes())

# 1. inbox topic is deterministic + a valid 4-segment content topic
let t1 = inboxTopicFor(bobChat)
let t2 = inboxTopicFor(bobChat)
doAssert t1 == t2
doAssert t1.count('/') == 4 and t1.startsWith("/muster/1/")
# 0x-prefix and case don't change it (normalized) — a sender may hold the id either way
doAssert inboxTopicFor(bobChat) == inboxTopicFor(bobChat.toUpperAscii())
# distinct recipients ⇒ distinct inboxes
doAssert inboxTopicFor(bobChat) != inboxTopicFor(toHex(alice.identity().toBytes()))
echo "1. inbox topic deterministic, valid, per-identity OK"

# 2. an invite sealed to Bob opens for Bob…
let payload = "{\"topic\":\"/muster/1/pay.demo/proto\",\"from\":\"alice\"}"
var pt: seq[byte] = @[]
for c in payload: pt.add byte(c)
let sealed = sealTo(bob.identity().x, pt)
let opened = bob.sealOpen(sealed)
var got = ""
for b in opened: got.add char(b)
doAssert got == payload
echo "2. invite sealed to recipient opens for them OK"

# …and NOT for anyone else (a sealed box is addressed)
var leaked = false
try:
  discard alice.sealOpen(sealed)
  leaked = true            # opened someone else's invite — must not happen
except CatchableError:
  discard
doAssert not leaked
echo "3. a non-recipient cannot open the invite OK"

echo "invites_test: all OK"
