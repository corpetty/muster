## s3 — offers are graded about the asking participant ONLY
## (contracts/specs/derived-exo-45e, oracle s3; property/trace).
##
## The invariant, checked directly: `offersFor` takes the caller's OWN catalogue and the
## manifest — it has no parameter through which another member's holdings could enter. So
## for MANY random other-member catalogues, my offers are byte-identical, and no other
## member's public face or handle ever appears in my offers. A regression that read across
## members (or leaked another's material into a candidate) would break one of these and
## flip the flag. Emits a JSON measurement + the trace flag; self-asserts now.

import std/[json, strutils]
import ../../src/coordination/offers
import ../../src/drivers/driver
import ../../src/drivers/manifest
import ../../src/wallet/material
import ../../src/intents/disclosure

let desc = DriverDescriptor(rounds: 1, threshold: 2,
                            finality: finExternal, serializationDomain: "eip712.safe.v1.4.1")
let m = ActionManifest(declared: true, agreement: desc,
  requirements: @[req(rqAuthority, "safe-owner", rpContributor),
                  req(rqAddress, "payee", rpCounterparty, need(mcAddress, "chain:31337", "to"))],
  discloses: @[row("to", obChainObserver)])

# MY catalogue — fixed.
let myCat = @[
  Material(class: mcAuthority, chain: "", form: "secp256k1", handle: "keystore:secp",
           public: "0xMINE", grade: mgVerifiedLocally, source: msKeystore),
  Material(class: mcAddress, chain: "evm:31337", form: "public", handle: "adapter:evm:31337:0xMY",
           public: "0xMY", grade: mgAttested, source: msAdapter)]

# A tiny deterministic PRNG so the probe is reproducible without external deps.
var rngState: uint64 = 0x9e3779b97f4a7c15'u64
proc nextR(): uint64 = (rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64; rngState)

let baseline = $recipientOffers(m.requirements, myCat, m)
var invariantHeld = true
var otherTokensSeen = 0
const trials = 200

for t in 0 ..< trials:
  # a random OTHER member's catalogue — varied size, chains, and unique public faces.
  var theirs: seq[Material]
  let n = int(nextR() mod 6)
  for i in 0 ..< n:
    let tag = "0xOTHER" & $t & "_" & $i & "_" & $(nextR() mod 100000)
    let isAuth = (nextR() mod 2) == 0
    theirs.add Material(
      class: (if isAuth: mcAuthority else: mcAddress),
      chain: (if isAuth: "" else: "evm:31337"),
      form: (if isAuth: "secp256k1" else: "public"),
      handle: "other:" & tag, public: tag,
      grade: mgAttested, source: msAdapter)
  # My offers are computed from MY catalogue only — theirs is never a parameter.
  let mine = recipientOffers(m.requirements, myCat, m)
  if $mine != baseline: invariantHeld = false
  # No other member's public/handle can appear in my offers.
  let s = $mine
  for mat in theirs:
    if s.contains(mat.public) or s.contains(mat.handle): inc otherTokensSeen

let offersIndependentOfOthers = invariantHeld and otherTokensSeen == 0
echo %*{"trials": trials, "invariantHeld": invariantHeld, "otherTokensSeen": otherTokensSeen,
        "offers_independent_of_others": offersIndependentOfOthers}

doAssert invariantHeld, "my offers changed when another member's catalogue changed"
doAssert otherTokensSeen == 0, "another member's material appeared in my offers"
echo "probe_offers_about_me_only: OK (", trials, " trials, offers invariant to others, nothing leaked)"
