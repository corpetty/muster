## Leaving a room (exo-dcc.28): the member stops following it here. Its session takes no
## more of the room's traffic, so a left room can't fill memory or reappear, and joining
## it again on the same topic reads it back from the store and the keystore.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/[strutils, sequtils]
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

const topic = "/muster/1/leave-room/proto"
let net = newLocalNetwork()
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
doAssert alice.admitInvited(bobKs.encIdentity())
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
bob.catchUp()
alice.publish(Event(key: "msg/1", value: "while-bob-is-here"))
doAssert bob.log.allEvents().anyIt(it.value == "while-bob-is-here")
echo "1. a member follows the room OK"

bob.leave()
alice.publish(Event(key: "msg/2", value: "after-bob-left"))
doAssert not bob.log.allEvents().anyIt(it.value == "after-bob-left"),
         "a left room's session takes no more of its traffic"
echo "2. after leaving, nothing more arrives OK"

let back = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
back.catchUp()
doAssert bobKs.encIdentity() in back.members(), "joining again: still a member (the grant is in the store)"
doAssert back.log.allEvents().anyIt(it.value == "after-bob-left"), "and the room reads back"
echo "3. joining again reads the room back OK"
echo "leave_room_test: all OK"
