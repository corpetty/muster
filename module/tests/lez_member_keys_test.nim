## A member's LEZ account keys, held in the keystore (exo-3c9: the live binding).
##
## The LEZ multisig claims every member account at create, so each membership needs a
## FRESH account. The keystore derives one key per label from its own secret. The secret
## never leaves, and state is still "log + keys" (invariant 4): the label is what the room
## records.
##   1. derivation: child = HMAC-SHA256(secret, "muster/lez-member-key/v1" 0x00 label 0x00
##      counter), the first counter giving a valid scalar. The x-only keys are pinned to an
##      independent implementation (Python hmac + affine secp256k1);
##   2. deterministic per (keystore, label); labels differ; keystores differ; it is not the
##      authorization key itself; an empty label is refused;
##   3. the signature is BIP-340 over the message hash, verifies under the member key,
##      is deterministic (zero aux), and is 64 bytes;
##   4. a file keystore derives the same member keys after reopening;
##   5. the chain's account id for the member key is publicAccountId(x-only).
## Needs the secp closure + libsodium — see tests/README.md.

import std/[os, strutils]
import ../src/crypto/keystore
import ../src/bitcoin/keys
import ../src/bitcoin/tx             # toHex
import ../src/hashing/sha256
import ../src/lez/tx as leztx

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

let ks = newInMemoryKeystore(seed(1), seed(2))

# ── 1. derivation, pinned ─────────────────────────────────────────────────────
doAssert toHex(ks.lezMemberKey("room-a/multisig-1")) == "935d7238a341889e706d24abe86238fa2b506b12b7128a7f6913f1e89c99ade3"
doAssert toHex(ks.lezMemberKey("room-a/multisig-2")) == "0c925686e29f94c1dbf9f3f2d5ac162f62a60d348d856da390a228f5d6c106c3"
echo "1. member keys: HMAC-SHA256(secret, domain ‖ label ‖ counter), pinned to an independent implementation OK"

# ── 2. properties ─────────────────────────────────────────────────────────────
let k1 = ks.lezMemberKey("room-a/multisig-1")
doAssert k1.len == 32 and ks.lezMemberKey("room-a/multisig-1") == k1, "deterministic"
doAssert ks.lezMemberKey("room-a/multisig-2") != k1, "labels differ"
doAssert newInMemoryKeystore(seed(3), seed(2)).lezMemberKey("room-a/multisig-1") != k1, "keystores differ"
doAssert k1 != xonlyPubKey(seed(1)), "not the authorization key"
var refused = false
try: discard ks.lezMemberKey("")
except KeystoreError: refused = true
doAssert refused, "an empty label is refused"
echo "2. deterministic per label, distinct across labels and keystores, never the authorization key OK"

# ── 3. BIP-340 signing ────────────────────────────────────────────────────────
let h = sha256(cast[seq[byte]]("a LEZ message hash"))
let sig = ks.lezMemberSign("room-a/multisig-1", h)
doAssert sig.len == 64 and schnorrVerify(sig, h, k1), "BIP-340 under the member key"
doAssert ks.lezMemberSign("room-a/multisig-1", h) == sig, "zero aux: deterministic"
doAssert not schnorrVerify(sig, h, ks.lezMemberKey("room-a/multisig-2")), "only under its own key"
echo "3. BIP-340 signatures under the member key, deterministic OK"

# ── 4. a file keystore, reopened ──────────────────────────────────────────────
let dir = getTempDir() / "muster-lez-member-keys-test"
removeDir(dir)
createDir(dir)
let path = dir / "k.mks"
let a = openFileKeystore(path, "pass", secpSeed = @(seed(1)), encSeedIn = @(seed(2)))
doAssert a.lezMemberKey("room-a/multisig-1") == k1, "the same secret derives the same member key"
let b = openFileKeystore(path, "pass")
doAssert b.lezMemberKey("room-a/multisig-1") == k1 and b.lezMemberSign("room-a/multisig-1", h) == sig
removeDir(dir)
echo "4. a file keystore derives the same member keys after reopening OK"

# ── 5. the chain's account id ─────────────────────────────────────────────────
let id = publicAccountId(k1)
doAssert id.len == 32 and id != publicAccountId(ks.lezMemberKey("room-a/multisig-2"))
echo "5. the member's LEZ account id is publicAccountId(x-only) OK"

echo "lez_member_keys_test: fresh LEZ member keys per label, in the keystore, never exported — all OK"
