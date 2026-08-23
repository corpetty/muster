## FS-4 stopgap test for FileKeystore: identity persists across "restarts" (re-open),
## the seam signs and does ECDH without ever exposing the secret, and a wrong
## passphrase or a tampered keyfile is refused. Needs libsecp256k1 + libsodium
## linked (see tests/README.md).

import std/[os, streams]
import ../src/crypto/keystore
import ../src/crypto/secp256k1

let dir = getTempDir() / "muster-keystore-test"
removeDir(dir)
createDir(dir)
let path = dir / "identity.mks"
let pass = "correct horse battery staple"

# 1. First open mints and persists an identity.
let ks1 = openFileKeystore(path, pass)
doAssert fileExists(path), "the keyfile is written on first open"
let addr1 = ks1.address()
echo "1. minted identity ", addr1

# 2. Re-open (a "restart") recovers the SAME identity — this is the whole point.
let ks2 = openFileKeystore(path, pass)
doAssert ks2.address() == addr1, "re-open recovers the same address"
doAssert ks2.pubKey() == ks1.pubKey(), "re-open recovers the same encryption key"
echo "2. identity survived a restart"

# 3. sign() produces an Ethereum signature that recovers to our address — the key
#    signed without the caller ever holding it.
var msg: array[32, byte]
for i in 0 ..< 32: msg[i] = byte(i)
let sig = ks1.sign(msg)
doAssert ecrecover(msg, sig) == addr1, "our signature recovers to our address"
echo "3. sign() recovers to the identity"

# 4. ecdh() agrees with a second keystore — symmetric, and the same key that signs
#    is the key that agrees (ADR-010: one curve).
let path2 = dir / "peer.mks"
let peer = openFileKeystore(path2, "another passphrase entirely")
let sharedFromUs = ks1.ecdh(peer.pubKey())
let sharedFromPeer = peer.ecdh(ks1.pubKey())
doAssert sharedFromUs == sharedFromPeer, "ECDH is symmetric across the seam"
echo "4. ECDH agrees between two keystores"

# 5. A wrong passphrase cannot open the identity (Argon2id + Poly1305 refuse it).
var wrongFailed = false
try:
  discard openFileKeystore(path, "not the passphrase")
except KeystoreError:
  wrongFailed = true
doAssert wrongFailed, "a wrong passphrase is refused"
echo "5. wrong passphrase refused"

# 6. A tampered keyfile is refused, not silently accepted — flip one ciphertext byte.
block:
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  for i in 0 ..< raw.len: bytes[i] = byte(raw[i])
  bytes[^1] = bytes[^1] xor 0xFF'u8       # last byte is inside the sealed region
  let fs = newFileStream(path, fmWrite)
  fs.writeData(addr bytes[0], bytes.len)
  fs.close()
var tamperFailed = false
try:
  discard openFileKeystore(path, pass)
except KeystoreError:
  tamperFailed = true
doAssert tamperFailed, "a tampered keyfile is refused"
echo "6. tampered keyfile refused"

removeDir(dir)
echo "keystore_test: all OK"
