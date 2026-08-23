## F-16 property test for the EpochCrypto stopgap: a member added mid-conversation
## provably cannot open an earlier epoch, and a removed member cannot open a later
## one. This is the "verify, not trust" bar that drove ADR-010. Members are now
## encryption identities (F-14 two-identity model); grants wrap to their X25519
## key. Needs libsecp256k1 + libsodium (see tests/README.md).

import std/strutils
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

# Each participant's keystore holds a secp authorization key + an encryption
# identity; the room identity (Member) is the encryption identity.
let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let carolKs = newInMemoryKeystore(key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"), seed(3))
let malKs   = newInMemoryKeystore(key("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(4))
let bobMem = bobKs.encIdentity()
let carolMem = carolKs.encIdentity()

# Alice founds the conversation (epoch 0). Adding Bob opens epoch 1.
let alice = newEpochCrypto(aliceKs)
alice.addMember(bobMem)
let bob = newEpochJoiner(bobKs)
bob.ingestGrant(alice.grantFor(1, bobMem))

let m1 = @[byte 11, 22, 33]
let e1 = alice.seal(m1)
doAssert bob.open(e1) == m1, "an epoch-1 member opens an epoch-1 envelope"
doAssert alice.epoch() == 1 and bobMem in alice.members()
echo "1. epoch-1 roundtrip OK"

# Adding Carol opens epoch 2; both current members are granted the new key.
alice.addMember(carolMem)
let carol = newEpochJoiner(carolKs)
carol.ingestGrant(alice.grantFor(2, carolMem))
bob.ingestGrant(alice.grantFor(2, bobMem))
let m2 = @[byte 44, 55]
let e2 = alice.seal(m2)
doAssert carol.open(e2) == m2 and bob.open(e2) == m2, "epoch-2 members open epoch-2"
echo "2. epoch-2 roundtrip OK"

# F-16 (joiner forward secrecy): Carol joined at epoch 2 and holds ONLY the
# epoch-2 key. She must not be able to open the epoch-1 envelope.
var joinerBlocked = false
try: discard carol.open(e1)
except CatchableError: joinerBlocked = true
doAssert joinerBlocked, "F-16: a member added at epoch 2 MUST NOT open an epoch-1 envelope"
doAssert bob.open(e1) == m1, "an original member still opens the earlier epoch"
echo "3. F-16 forward secrecy (joiner cannot read earlier epochs) OK"

# F-16 (removal): remove Bob -> epoch 3. Bob held epochs 1 and 2, but is absent
# from epoch 3 and never receives its key, so he cannot open epoch-3 traffic.
alice.removeMember(bobMem)
carol.ingestGrant(alice.grantFor(3, carolMem))
doAssert bobMem notin alice.members(), "removed member is gone from the current set"
let m3 = @[byte 99]
let e3 = alice.seal(m3)
doAssert carol.open(e3) == m3, "a remaining member opens epoch-3"
var removedBlocked = false
try: discard bob.open(e3)
except CatchableError: removedBlocked = true
doAssert removedBlocked, "F-16 removal: a removed member MUST NOT open a later epoch"
echo "4. F-16 removal (removed member cannot read later epochs) OK"

# A grant wrapped to Carol must not unwrap with anyone else's key (the sealed box
# is to the recipient's X25519 key; a non-recipient's open fails the AEAD tag).
var nonRecipientBlocked = false
try: discard malKs.sealOpen(alice.grantFor(3, carolMem).wrappedKey)
except CatchableError: nonRecipientBlocked = true
doAssert nonRecipientBlocked, "a grant wrapped to Carol must not unwrap with a different key"
echo "5. non-recipient cannot unwrap a grant OK"

echo "epoch_crypto_test: all OK"
