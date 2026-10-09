## Inviting someone admits them (exo-dcc.29). A member who names a person's encryption
## identity — the invite — has made the membership decision, so the room keys them in
## then: the invitee needs no join request and no one has to press Admit. Held here:
##   1. a member admits a named identity with no request (the grant waits in the store);
##   2. the invitee, arriving later, catches up and is a member, with no request sent;
##   3. it reads what is said after the invite, and nothing from before it (F-16);
##   4. only a member can admit: an outsider's invite admits nobody;
##   5. inviting someone already in the room does not re-key it.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/strutils
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/coordination/session

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let malKs   = newInMemoryKeystore(key("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(3))
let carolKs = newInMemoryKeystore(key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"), seed(4))

const topic = "/muster/1/invite-admits/proto"
let net = newLocalNetwork()
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
alice.publish(Event(key: "msg/1", value: "before-the-invite"))

# 1. Alice invites Bob by the identity she holds for him. No request from Bob exists.
doAssert alice.admitInvited(bobKs.encIdentity()), "a member's invite admits the named identity"
doAssert bobKs.encIdentity() in alice.members()
alice.publish(Event(key: "msg/2", value: "after-the-invite"))
echo "1. a member admits the identity it names, with no request OK"

# 2. Bob arrives afterwards (a fresh session: he only learnt the topic from the invite)
# and catches up from the store. He sends no join request.
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
bob.catchUp()
doAssert bobKs.encIdentity() in bob.members(), "the invitee is a member on arrival"
doAssert aliceKs.encIdentity() in bob.members()
echo "2. the invitee is a member on arrival, no ask OK"

# 3. F-16 still holds: what was said after the invite reads; what was said before it doesn't.
var vals: seq[string]
for e in bob.log.allEvents(): vals.add e.value
doAssert "after-the-invite" in vals, "the invitee reads the room from the invite on"
doAssert "before-the-invite" notin vals, "never the history before it (F-16)"
echo "3. reads from the invite on, nothing before it (F-16) OK"

# 4. Mallory is no member of this room; her invite of Carol admits no one.
let mal = newCoordinationSession(newLocalTransport(net), newEpochJoiner(malKs), topic)
mal.catchUp()
doAssert not mal.admitInvited(carolKs.encIdentity()), "an outsider's invite admits nobody"
doAssert carolKs.encIdentity() notin alice.members()
echo "4. only a member's invite admits OK"

# 5. Inviting Bob again (a resent invite) leaves the epoch alone.
let before = alice.epoch()
doAssert alice.admitInvited(bobKs.encIdentity()), "already a member: still in"
doAssert alice.epoch() == before, "no re-key for someone already in the room"
echo "5. re-inviting a member does not re-key OK"
echo "invite_admits_test: all OK"
