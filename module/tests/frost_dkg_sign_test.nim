## The two drafts compose (Phase D, exo-fae + exo-d7e): a key made by a ChillDKG ceremony
## signs under BIP-445 FROST, and what comes out is ONE plain BIP-340 signature.
##   1. a 2-of-3 ceremony run end to end — three participants, the (untrusted, relaying)
##      coordinator — gives every participant the same threshold key and public shares,
##      each its own secret share, and the same recovery data;
##   2. the threshold key is a taproot output key already (ChillDKG commits it to an
##      unspendable script path), so its x-only form is the address's key;
##   3. any two of the three sign in two rounds (nonces, then partial signatures, each
##      verified against the signer's public share); the aggregate verifies with
##      libsecp256k1's own BIP-340 verifier under that x-only key — a signature a chain
##      cannot tell from single-sig — and a pair that includes a wrong share does not;
##   4. recovery data alone gives a participant back its secret share.
## Needs the secp closure + stint — see tests/README.md.

import std/[options, sequtils, sysrand, strutils]
import ../src/frost/[secp, signing, chilldkg]
import ../src/bitcoin/[keys, bech32]
import ../src/hashing/sha256

proc rnd(): seq[byte] =
  result = newSeq[byte](32)
  doAssert urandom(result)

let hostsecs = @[rnd(), rnd(), rnd()]
let params = SessionParams(hostpubkeys: hostsecs.mapIt(hostpubkeyGen(it)), t: 2)

# ── 1. the ceremony ────────────────────────────────────────────────────────────
var st1: seq[ParticipantState1]
var pmsgs1: seq[seq[byte]]
for h in hostsecs:
  let (s, m) = participantStep1(h, params, rnd())
  st1.add s
  pmsgs1.add m
let (cstate, cmsg1) = coordinatorStep1(pmsgs1, params)
var st2: seq[ParticipantState2]
var pmsgs2: seq[seq[byte]]
for i, h in hostsecs:
  let (s, m) = participantStep2(h, st1[i], cmsg1, rnd())
  st2.add s
  pmsgs2.add m
let (cmsg2, cout, crec) = coordinatorFinalize(cstate, pmsgs2)
var outs: seq[DkgOutput]
for i in 0 ..< 3:
  let (o, rec) = participantFinalize(st2[i], cmsg2)
  doAssert rec == crec, "everyone holds the same recovery data"
  doAssert o.threshPk == cout.threshPk and o.pubshares == cout.pubshares
  doAssert o.secshare.isSome and pointFromCompressed(o.pubshares[i]) == mulG(scalarFromBytesChecked(o.secshare.get))
  outs.add o
echo "1. a 2-of-3 ChillDKG: one threshold key and set of public shares for all, a secret share each OK"

# ── 2. the taproot key ─────────────────────────────────────────────────────────
let xonly = pointFromCompressed(cout.threshPk).toXonly()
let address = encodeSegwitAddress("bcrt", 1, xonly)
doAssert address.startsWith("bcrt1p")
echo "2. the threshold key is the taproot output key: ", address, " OK"

# ── 3. any two sign ────────────────────────────────────────────────────────────
let msg = @(sha256(cast[seq[byte]]("a key-path sighash")))
proc signWith(ids: seq[int], shares: seq[seq[byte]]): seq[byte] =
  var secnonces, pubnonces: seq[seq[byte]]
  for k, id in ids:
    let (sn, pn) = nonceGen(some(shares[k]), some(outs[id].pubshares[id]), some(xonly), some(msg), none(seq[byte]))
    secnonces.add sn
    pubnonces.add pn
  let agg = nonceAgg(pubnonces)
  let ctx = SessionContext(n: 3, t: 2, ids: ids, pubshares: some(ids.mapIt(cout.pubshares[it])),
                           threshPk: cout.threshPk, aggnonce: agg, msg: msg)
  var psigs: seq[seq[byte]]
  for k, id in ids:
    var sn = secnonces[k]
    let ps = sign(sn, shares[k], id, ctx)
    doAssert partialSigVerify(ps, pubnonces, 3, 2, ids, ids.mapIt(cout.pubshares[it]), cout.threshPk, @[], @[], msg, k)
    psigs.add ps
  partialSigAgg(psigs, ctx)

for ids in [@[0, 1], @[0, 2], @[1, 2], @[2, 0]]:
  let sig = signWith(ids, ids.mapIt(outs[it].secshare.get))
  doAssert sig.len == 64 and schnorrVerify(sig, msg, xonly), "libsecp verifies the aggregate for " & $ids
var raised = false
try: discard signWith(@[0, 1], @[outs[0].secshare.get, outs[2].secshare.get])
except ValueError: raised = true
doAssert raised, "a share that is not the signer's is refused"
echo "3. every pair signs; the aggregate is one BIP-340 signature libsecp accepts OK"

# ── 4. recovery ────────────────────────────────────────────────────────────────
let (rec1, p1) = participantRecover(hostsecs[1], crec)
doAssert rec1.secshare == outs[1].secshare and rec1.threshPk == cout.threshPk and p1.hostpubkeys == params.hostpubkeys
echo "4. the recovery data alone gives a participant back its secret share OK"

echo "frost_dkg_sign_test: a ChillDKG key signs under FROST as one plain BIP-340 signature — all OK"
