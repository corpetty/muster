## An in-room approval signed by keystore_module (exo-149.2 K2), with the keystore played
## by alice's own key signing exactly the legs' hashes. Held: the request is the SafeTx
## as a typed_data leg that hashes to the intent's safeTxHash, plus muster's attestation
## digest over P; signatures that come back and check (keystore_requests) publish as an
## approval the fold counts like a native one — with bob's in-app approval the Safe
## intent reaches executable; an account that is not a signer is refused before any
## human is asked; legs signed in the wrong order are rejected; an intent that expired
## while the human decided, or whose P moved, publishes nothing; and a kind other than
## the Safe is refused for now.

import std/[json, strutils]
import ../src/crypto/secp256k1
import ../src/wallet/keystore_legs
import ../src/wallet/keystore_requests
import ../src/coordination/keystore_approval
import ./probes/live_room

proc hexSig(s: Signature65): string =
  result = "0x"
  for b in s: result.add toHex(b).toLowerAscii()

proc hexAddr(a: Address): string =
  result = "0x"
  for b in a: result.add toHex(b).toLowerAscii()

let alice = hexAddr(aliceKs.address())

proc keystoreSigns(req: KeystoreApproval): seq[string] =
  ## What keystore_module returns once alice approves: one signature per leg, by her key,
  ## over each leg's hash (typed_data: the EIP-712 signing hash; digest: the 32 bytes).
  for leg in req.legs: result.add hexSig(aliceKs.sign(leg.hash))

block theRequest:
  var r = newRoom("/muster/1/ks-approval-1/proto")
  let id = r.propose("safe", effectFor("safe", 41))
  let req = planKeystoreApproval(r.alice, liveDriverFor, id, alice, Now)
  doAssert req.refusal == "", req.refusal
  let legs = req.intent["legs"]
  doAssert req.intent["address"].getStr() == alice and legs.len == 2
  doAssert legs[0]["kind"].getStr() == "typed_data" and legs[1]["kind"].getStr() == "digest"
  doAssert typedDataHash(legs[0]["typed_data"]) == req.legs[0].hash      # what the signer hashes = safeTxHash
  var attestHex = "0x"
  for b in req.legs[1].hash: attestHex.add toHex(b).toLowerAscii()
  doAssert legs[1]["digest"].getStr() == attestHex                       # the attestation digest it checks
  doAssert "Muster attestation (interim)" in legs[1]["purpose"].getStr()
  echo "1. the request: the SafeTx as a typed_data leg hashing to the safeTxHash, and the attestation digest OK"

block countsLikeNative:
  var r = newRoom("/muster/1/ks-approval-2/proto")
  let id = r.propose("safe", effectFor("safe", 42))
  let req = planKeystoreApproval(r.alice, liveDriverFor, id, alice, Now)
  var pending: SignRequests
  pending.add("ksh_t", "ksc_t", id, alice, req.legs, deadline = 1e12)
  let got = pending.onFetched("ksh_t", %*{"ok": true, "signed": keystoreSigns(req)})
  doAssert got.ok, got.reason
  doAssert publishKeystoreApproval(r.alice, liveDriverFor, id, req, got.sigs, Now) == "collecting"
  r.bob.poll()
  doAssert r.approveAs("bob", id) == "executable"
  echo "2. a keystore-signed approval counts like a native one: with bob's, executable OK"

block refusals:
  var r = newRoom("/muster/1/ks-approval-3/proto")
  let id = r.propose("safe", effectFor("safe", 43))
  doAssert planKeystoreApproval(r.alice, liveDriverFor, id, "0x" & "ab".repeat(20), Now).refusal == "not-a-signer"
  let req = planKeystoreApproval(r.alice, liveDriverFor, id, alice, Now)
  let sigs = keystoreSigns(req)
  doAssert publishKeystoreApproval(r.alice, liveDriverFor, id, req, @[sigs[1], sigs[0]], Now) == "rejected"
  doAssert publishKeystoreApproval(r.alice, liveDriverFor, id, req, sigs,
                                   Now + uint64(Ttl) + 1) == "expired"
  var moved = req
  moved.p = moved.p & @[0x00'u8]
  doAssert publishKeystoreApproval(r.alice, liveDriverFor, id, moved, sigs, Now) == "inputs-changed"
  let thr = r.propose("threshold", effectFor("threshold", 44))
  doAssert planKeystoreApproval(r.alice, liveDriverFor, thr, alice, Now).refusal == "keystore-unsupported-kind"
  echo "3. not a signer, legs swapped, expired, P moved, another kind: each refused, nothing published OK"

echo "keystore_approval_test: all passed"
