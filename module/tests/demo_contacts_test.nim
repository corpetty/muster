## Golden vectors for the demo pre-seeded identities (exo-1fc).
##
## A seeded demo peer derives a DETERMINISTIC encryption (chat) identity from its anvil
## secp key, so every role's room-membership id is known ahead of time and peers can be
## pre-seeded as each other's contacts. For that to hold cross-peer, the derivation must be
## stable — the same secp key must always yield the same chat id, on every machine and
## build. This test pins the derivation (mirroring muster_module's private `demoEncSeed` /
## `demoChatIdOf`) to golden vectors: if the crypto primitives or the domain label ever
## change output, the pre-seeded contacts would silently stop matching the roster, and this
## fails first. The three addresses must also be the anvil Safe owners (0/1/2).

import std/strutils
import ../src/crypto/curve25519
import ../src/crypto/secp256k1
import ../src/hashing/sha256

proc hexSeed32(hexIn: string): seq[byte] =
  var h = hexIn.strip()
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2:
    result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc demoEncSeed(secpSeed: openArray[byte]): array[32, byte] =
  var buf = newSeq[byte]()
  for c in "muster-demo-enc-v1": buf.add byte(c)
  for b in secpSeed: buf.add b
  sha256(buf)

proc toArr32(s: seq[byte]): array[32, byte] =
  for i in 0 ..< min(32, s.len): result[i] = s[i]

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc chatIdOf(seed: seq[byte]): string =
  toHex(encFromSeed(demoEncSeed(seed)).identity().toBytes())

const
  AliceKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  BobKey   = "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  CarolKey = "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

  # golden chat ids (ed25519 ++ x25519) — recompute with tools, then update ONLY on a
  # deliberate derivation change (which is a demo-breaking, coordinate-with-the-runbook one)
  AliceChat = "0xcd3930fefce17daeba560f92b088ee16b2ac52067ba028d1e9bb1a6ea1e9954d7563dcc927c1a986ecfa833b4e026a1fdacc174092a7d56f0644463af0e2e208"
  BobChat   = "0x34bd8ae3fb46fe30f0f0e26239cf2061ce91ebd295b9c23e42f3d960d20440bf1ddfb1eb763ffd609f65a03d8e76350a31e967daea48f50040cc94d87972da40"
  CarolChat = "0x0a339f31d13c13df00f5ad04582f8d24435e78a5b5dec081376bd4c103cfc6da29825721100cfd187529a19f5d842f78feced257c553a11b6193ba6476f6dd59"

  # the anvil Safe owners (0/1/2) — the address a pre-seeded contact carries
  AliceAddr = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  BobAddr   = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  CarolAddr = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"

proc addrOf(seed: seq[byte]): string = toHex(addressOf(toArr32(seed)))

# 1. deterministic — the same key always yields the same chat id
doAssert chatIdOf(hexSeed32(AliceKey)) == chatIdOf(hexSeed32(AliceKey))
echo "1. derivation is deterministic OK"

# 2. golden chat ids — cross-peer stability (the pre-seed depends on these exact values)
doAssert chatIdOf(hexSeed32(AliceKey)) == AliceChat
doAssert chatIdOf(hexSeed32(BobKey))   == BobChat
doAssert chatIdOf(hexSeed32(CarolKey)) == CarolChat
echo "2. golden chat ids match OK"

# 3. distinct roles → distinct ids
doAssert AliceChat != BobChat and BobChat != CarolChat and AliceChat != CarolChat
echo "3. roles are distinct OK"

# 4. the seeded addresses are the anvil Safe owners 0/1/2
doAssert addrOf(hexSeed32(AliceKey)) == AliceAddr
doAssert addrOf(hexSeed32(BobKey))   == BobAddr
doAssert addrOf(hexSeed32(CarolKey)) == CarolAddr
echo "4. addresses are anvil owners 0/1/2 OK"

echo "demo_contacts_test: all OK"
