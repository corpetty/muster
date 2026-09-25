## Round secrets as keystore operations (Phase D, exo-a50.4.4; seam S7 of
## docs/design/multisig-landscape.md). A FROST member never holds a share or a nonce
## outside its keystore, and a nonce is never used twice:
##   1. the host key: one per label, derived from the keystore secret, public as a
##      33-byte key; the keystore signs with it (BIP-340, for attestations);
##   2. a 2-of-3 ChillDKG through three keystores: step 1, step 2, finalize, with the
##      coordinator's steps computed from the messages alone. All three reach the same
##      threshold key and public shares, and the secret share never leaves (the output
##      carries none);
##   3. two members sign: nonce commit, then partial signatures; the aggregate is ONE
##      BIP-340 signature libsecp accepts under the threshold key's x-only form;
##   4. a nonce is consumed before it is used: signing twice in one session is refused,
##      and so is a second nonce commit for a session;
##   5. a restart aborts the session and never reuses a nonce: a keystore reopened with
##      the same secret recovers its share from the PUBLIC recovery data (so the share is
##      "log + keys", invariant 4, never stored), but the old session's nonce is gone,
##      so it refuses to sign. A fresh session signs;
##   6. a file keystore gives the same host key after reopening.
## Needs the secp closure + stint + libsodium — see tests/README.md.

import std/[os, options, sequtils, strutils]
import ../src/crypto/keystore
import ../src/frost/[secp, signing, chilldkg]
import ../src/bitcoin/keys
import ../src/hashing/sha256

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

let (ka, kb, kc) = (newInMemoryKeystore(seed(1), seed(11)), newInMemoryKeystore(seed(2), seed(12)),
                    newInMemoryKeystore(seed(3), seed(13)))
let kss = @[Keystore(ka), Keystore(kb), Keystore(kc)]
const L = "room-x/treasury"

# ── 1. host keys ──────────────────────────────────────────────────────────────
let hosts = kss.mapIt(it.frostHostPubkey(L))
doAssert hosts.allIt(it.len == 33) and hosts[0] != hosts[1] and ka.frostHostPubkey(L) == hosts[0]
doAssert ka.frostHostPubkey("another") != hosts[0], "one host key per label"
let d = sha256(cast[seq[byte]]("an attestation digest"))
doAssert schnorrVerify(ka.frostHostSign(L, d), d, xonlyOfCompressed(hosts[0])), "the keystore signs with its host key"
echo "1. a host key per label, derived in the keystore; it signs, it is never exported OK"

# ── 2. the ceremony ───────────────────────────────────────────────────────────
let params = SessionParams(hostpubkeys: hosts, t: 2)
let pmsgs1 = kss.mapIt(it.frostDkgStep1(L, params))
let (cst, cmsg1) = coordinatorStep1(pmsgs1, params)
let pmsgs2 = kss.mapIt(it.frostDkgStep2(L, params, cmsg1))
let (cmsg2, cout, crec) = coordinatorFinalize(cst, pmsgs2)
var outs: seq[DkgOutput]
for k in kss:
  let (o, rec) = k.frostDkgFinalize(L, params, cmsg2)
  doAssert rec == crec and o.threshPk == cout.threshPk and o.pubshares == cout.pubshares
  doAssert o.secshare.isNone, "the secret share never leaves the keystore"
  outs.add o
var raised = false
try: discard ka.frostDkgStep2(L, params, cmsg1)
except KeystoreError: raised = true
doAssert raised, "a ceremony step runs once"
echo "2. a 2-of-3 ChillDKG through three keystores: one threshold key, no share outside OK"

# ── 3. two sign ───────────────────────────────────────────────────────────────
let xonly = pointFromCompressed(cout.threshPk).toXonly()
let msgs = @[@(sha256(cast[seq[byte]]("input 0 sighash"))), @(sha256(cast[seq[byte]]("input 1 sighash")))]
proc signIn(session: string, signers: seq[int], who: seq[Keystore]): seq[seq[byte]] =
  let pubnonces = who.mapIt(it.frostNonceCommit(L, session, crec, msgs))
  let partials = who.mapIt(it.frostPartialSign(L, session, crec, signers, pubnonces, msgs))
  for j in 0 ..< msgs.len:
    let agg = nonceAgg(pubnonces.mapIt(it[j]))
    let ctx = SessionContext(n: 3, t: 2, ids: signers, pubshares: some(signers.mapIt(cout.pubshares[it])),
                             threshPk: cout.threshPk, aggnonce: agg, msg: msgs[j])
    result.add partialSigAgg(partials.mapIt(it[j]), ctx)
let sigs = signIn("intent-1", @[0, 2], @[kss[0], kss[2]])
for j in 0 ..< msgs.len:
  doAssert sigs[j].len == 64 and schnorrVerify(sigs[j], msgs[j], xonly), "one BIP-340 signature per input"
echo "3. two members sign two inputs in two rounds; each aggregate is one BIP-340 signature OK"

# ── 4. a nonce is consumed before it is used ──────────────────────────────────
let pn = @[kb.frostNonceCommit(L, "intent-2", crec, msgs), kc.frostNonceCommit(L, "intent-2", crec, msgs)]
raised = false
try: discard kb.frostNonceCommit(L, "intent-2", crec, msgs)
except KeystoreError: raised = true
doAssert raised, "one nonce commit per session"
discard kb.frostPartialSign(L, "intent-2", crec, @[1, 2], pn, msgs)
raised = false
try: discard kb.frostPartialSign(L, "intent-2", crec, @[1, 2], pn, msgs)
except KeystoreError: raised = true
doAssert raised, "a nonce signs once: the second partial signature is refused"
echo "4. a nonce commit per session, and a nonce consumed before it is used OK"

# ── 5. a restart aborts, and never reuses ─────────────────────────────────────
discard ka.frostNonceCommit(L, "intent-3", crec, msgs)
let kaAgain = newInMemoryKeystore(seed(1), seed(11))                 # the same secret, restarted
doAssert kaAgain.frostHostPubkey(L) == hosts[0]
raised = false
try: discard kaAgain.frostPartialSign(L, "intent-3", crec, @[0, 1], @[@[newSeq[byte](66), newSeq[byte](66)],
                                                                          @[newSeq[byte](66), newSeq[byte](66)]], msgs)
except KeystoreError as e:
  raised = "abort" in e.msg
doAssert raised, "after a restart the session aborts: no nonce, no signature"
let again = signIn("intent-4", @[0, 1], @[Keystore(kaAgain), kss[1]])
doAssert schnorrVerify(again[0], msgs[0], xonly), "the share comes back from the public recovery data"
echo "5. a restart recovers the share from the recovery data and aborts the old session OK"

# ── 6. a file keystore ────────────────────────────────────────────────────────
let dir = getTempDir() / "muster-frost-keystore-test"
removeDir(dir)
createDir(dir)
let f1 = openFileKeystore(dir / "k.mks", "pass")
let hk = f1.frostHostPubkey(L)
doAssert openFileKeystore(dir / "k.mks", "pass").frostHostPubkey(L) == hk
removeDir(dir)
echo "6. a file keystore gives the same host key after reopening OK"

echo "frost_keystore_test: FROST round secrets are keystore operations; a nonce is used once — all OK"
