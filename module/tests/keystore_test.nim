## FS-4 stopgap test for the two-identity keystore: both the secp256k1
## authorization key and the Ed25519/X25519 encryption identity persist across a
## restart; the seam signs, opens sealed grants, and issues the identity binding
## without exposing a secret; a wrong passphrase or tampered keyfile is refused.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/[os, streams, times]
import ../src/crypto/keystore
import ../src/crypto/secp256k1
import ../src/crypto/curve25519
import ../src/crypto/binding

let dir = getTempDir() / "muster-keystore-test"
removeDir(dir)
createDir(dir)
let path = dir / "identity.mks"
let pass = "correct horse battery staple"

# 1. First open mints and persists both identities.
let ks1 = openFileKeystore(path, pass)
doAssert fileExists(path), "the keyfile is written on first open"
let addr1 = ks1.address()
let enc1 = ks1.encIdentity()
echo "1. minted identity ", addr1

# 2. Re-open (a "restart") recovers BOTH identities unchanged.
let ks2 = openFileKeystore(path, pass)
doAssert ks2.address() == addr1, "re-open recovers the same secp address"
doAssert ks2.encIdentity() == enc1, "re-open recovers the same encryption identity"
echo "2. both identities survived a restart"

# 3. sign() produces a signature that recovers to our address — the key signed
#    without the caller holding it.
var msg: array[32, byte]
for i in 0 ..< 32: msg[i] = byte(i)
doAssert ecrecover(msg, ks1.sign(msg)) == addr1, "our signature recovers to our address"
echo "3. sign() recovers to the identity"

# 4. sealOpen() opens a grant sealed to our X25519 key; another keystore cannot.
let secret = @[byte 9, 8, 7, 6]
let sealed = sealTo(enc1.x, secret)
doAssert ks1.sealOpen(sealed) == secret, "we open a sealed box addressed to us"
let other = openFileKeystore(dir / "other.mks", "another passphrase")
var otherFailed = false
try: discard other.sealOpen(sealed)
except CatchableError: otherFailed = true
doAssert otherFailed, "another keystore cannot open our sealed box"
echo "4. sealOpen() addressed to us OK"

# 5. bindingFor() issues a secp<->enc binding that recovers to our own address and
#    vouches for our own encryption identity.
let ctx = LinkContext(account: "0xSafe", slot: "0", expiry: 1000)
let st = ks1.bindingFor(ctx)
doAssert st.enc == enc1, "the binding vouches for our encryption identity"
doAssert bindingBinds(st, @[addr1], now = 0), "our binding recovers to our own address"
echo "5. bindingFor() issues a valid binding"

# 6. A wrong passphrase cannot open the identity.
var wrongFailed = false
try: discard openFileKeystore(path, "not the passphrase")
except KeystoreError: wrongFailed = true
doAssert wrongFailed, "a wrong passphrase is refused"
echo "6. wrong passphrase refused"

# 7. A tampered keyfile is refused (flip a ciphertext byte).
block:
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  for i in 0 ..< raw.len: bytes[i] = byte(raw[i])
  bytes[^1] = bytes[^1] xor 0xFF'u8
  let fs = newFileStream(path, fmWrite)
  fs.writeData(addr bytes[0], bytes.len)
  fs.close()
var tamperFailed = false
try: discard openFileKeystore(path, pass)
except KeystoreError: tamperFailed = true
doAssert tamperFailed, "a tampered keyfile is refused"
echo "7. tampered keyfile refused"

# 8. Keyed operations (exo-45e K2b): a keystore holds a SET of keys, selected by ref.
block:
  proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let ks = newInMemoryKeystore(seed(1), seed(2))
  let primary = refOf(ks.address())
  doAssert ks.keyRefs() == @[primary], "one key to start; its ref is the primary address"
  doAssert ks.hasKey(primary) and not ks.hasKey("0xdeadbeef")
  # signWith(primary) == sign() (the single-key methods act on the primary).
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = byte(i)
  doAssert ks.signWith(primary, h) == ks.sign(h)
  # add a second key; both are now selectable, and each signs with ITS OWN key.
  let second = ks.addKey(seed(9), seed(10))
  doAssert ks.keyRefs().len == 2 and second in ks.keyRefs()
  doAssert ks.signWith(second, h) != ks.signWith(primary, h), "each ref signs with its own key"
  doAssert ks.edSignWith(second, h) != ks.edSignWith(primary, h)
  # an unknown ref is REFUSED — never a silent fall-through to another key.
  var refused = false
  try: discard ks.signWith("0xnope", h)
  except KeystoreError: refused = true
  doAssert refused, "signWith on an unknown ref must refuse"
  echo "8. keyed keystore: a set selected by ref; signWith refuses an unknown ref (K2b) OK"

# 9. FileKeystore is a keyfile SET: loadKeyfile adds a second key, selectable by ref.
block:
  let d2 = getTempDir() / ("mks-set-" & $epochTime().int)
  let p1 = d2 / "primary.mkf"
  let p2 = d2 / "second.mkf"
  let fk = openFileKeystore(p1, "pw1")                 # mints the primary
  let fk2 = openFileKeystore(p2, "pw2")                 # a separate keyfile
  let secondRef = refOf(fk2.address())
  fk.loadKeyfile(p2, "pw2")                             # add it to fk's set
  doAssert fk.keyRefs().len == 2 and secondRef in fk.keyRefs()
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = byte(0xA0 + i)
  doAssert fk.signWith(secondRef, h) == fk2.sign(h), "the loaded key signs as itself"
  doAssert fk.signWith(refOf(fk.address()), h) != fk.signWith(secondRef, h)
  removeDir(d2)
  echo "9. FileKeystore keyfile SET: loadKeyfile adds a selectable key (K2b) OK"

removeDir(dir)
echo "keystore_test: all OK"
