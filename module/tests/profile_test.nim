## The family profile (exo-a50.1.1, docs/design/multisig-landscape.md §5 S3/S9): every
## driver declares which multisig FAMILY it is and fills the family's facts for its
## instance, so the card reads one profile instead of branching on a concrete driver
## type. Held here to three things:
##   1. every registered driver kind declares a profile consistent with its own
##      describe() (checkProfileConformance) — a driver that does not say what kind
##      of multisig it is does not ship;
##   2. the profile agrees with contracts/families/registry.json, BOTH ways — each
##      driver's static facts equal its registry entry, and every family the registry
##      calls built/partial is declared by a driver (drift is a failure, not a doc bug);
##   3. instance facts are honest: CAIP-2 chain + CAIP-10 account for a chain family,
##      nothing for a room family, k/n from the instance, and a Safe's ways around the
##      threshold are UNKNOWN until they are read from the chain (never "none").
## Needs the secp closure (Safe, EIP-191) + libsodium (Ed25519) — see tests/README.md.

import std/[json, os, strutils, sequtils]
import ../src/crypto/secp256k1
import ../src/crypto/curve25519
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/registry
import ../src/drivers/conformance

const RegistryPath = currentSourcePath().parentDir() / ".." / ".." / "contracts" / "families" / "registry.json"
let reg = parseJson(readFile(RegistryPath))

proc entry(family: string): JsonNode =
  for f in reg["families"]:
    if f["id"].getStr() == family: return f
  nil

proc edHex(n: byte): string = "0x" & repeat(toHex(n, 2).toLowerAscii(), 32)
let roster = %*[edHex(1), edHex(2), edHex(3)]
let owners = %*["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"]
const SafeAddr = "0x5FbDB2315678afecb367f032d93F642f64180aa3"

# every kind the registry can build, with the source file the family names
let kinds = @[
  ("safe", %*{"chainId": 31337, "safe": SafeAddr, "owners": owners, "threshold": 2},
   "module/src/drivers/safe.nim"),
  ("threshold", %*{"roster": roster, "k": 2}, "module/src/drivers/threshold.nim"),
  ("frost", %*{"roster": roster, "k": 2}, "module/src/drivers/frost.nim"),
  ("invoke", %*{"roster": roster, "k": 2}, "module/src/drivers/invoke.nim"),
  ("eip191", %*{"signers": owners, "threshold": 1}, "module/src/drivers/eip191.nim")]

# ── 1. every registered kind declares a consistent profile ─────────────────────
block:
  for (kind, cfg, _) in kinds:
    let d = newDriver(kind, cfg)
    let r = checkProfileConformance(d)
    doAssert r.allPass(), kind & " profile must conform: failed " & $r.failed()
  echo "1. every registered driver declares a profile consistent with describe() OK"

# ── 2. the profile and the registry agree, both ways ─────────────────────────
block:
  var declared: seq[string]
  for (kind, cfg, file) in kinds:
    let p = newDriver(kind, cfg).profile()
    let e = entry(p.family)
    doAssert e != nil, kind & " declares family " & p.family & ", which the registry does not list"
    declared.add p.family
    doAssert e["muster"]["status"].getStr() in ["built", "partial"],
      p.family & " is declared by a driver but the registry calls it " & e["muster"]["status"].getStr()
    doAssert e["muster"]["driver"].getStr() == file,
      p.family & ": the registry names " & e["muster"]["driver"].getStr() & ", the driver is " & file
    let j = p.toJson()
    for field in ["settlement", "locus", "scheme", "commits", "binding", "ordering", "expiry",
                  "setup", "membershipChange", "approverCost", "maturity"]:
      doAssert j[field].getStr() == e[field].getStr(),
        p.family & "." & field & ": driver says " & j[field].getStr() & ", registry says " & e[field].getStr()
    for k in ["policy", "signers", "effect"]:
      doAssert j["reveals"][k].getStr() == e["reveals"][k].getStr(),
        p.family & ".reveals." & k & ": driver " & j["reveals"][k].getStr() & ", registry " & e["reveals"][k].getStr()
    doAssert j["rounds"].getInt() == e["rounds"].getInt(), p.family & ".rounds"
    doAssert j["secretState"].getBool() == e["secretState"].getBool(), p.family & ".secretState"
  for f in reg["families"]:
    if f["muster"]["status"].getStr() in ["built", "partial"]:
      doAssert f["id"].getStr() in declared,
        f["id"].getStr() & " is " & f["muster"]["status"].getStr() & " in the registry but no driver declares it"
  echo "2. driver profiles and the family registry agree, both ways OK"

# ── 3. instance facts: CAIP ids, k of n, honest unknowns ─────────────────────
block:
  let safe = newDriver("safe", %*{"chainId": 31337, "safe": SafeAddr, "owners": owners, "threshold": 2}).profile()
  doAssert safe.chain == "eip155:31337", safe.chain
  doAssert safe.account == "eip155:31337:" & SafeAddr.toLowerAscii(), safe.account
  doAssert safe.k == 2 and safe.n == 3
  doAssert not safe.bypassesKnown, "a Safe's modules are not read yet — its bypasses are unknown, never 'none'"
  let base = newDriver("safe", %*{"chainId": 8453, "safe": SafeAddr, "owners": owners, "threshold": 2}).profile()
  doAssert base.chain == "eip155:8453" and base.family == safe.family,
    "the same family on another chain is another ACCOUNT, not another family"
  for kind in ["threshold", "frost", "invoke"]:
    let p = newDriver(kind, %*{"roster": roster, "k": 2}).profile()
    doAssert p.chain == "" and p.account == "", kind & " is a room family: no chain, no account"
    doAssert p.k == 2 and p.n == 3, kind & " k/n from the roster"
    doAssert p.bypassesKnown and p.bypasses.len == 0, kind & ": nothing gets around a room threshold"
  let att = newDriver("eip191", %*{"signers": owners, "threshold": 1}).profile()
  doAssert att.k == 1 and att.n == 3
  echo "3. CAIP-2/10 for chain families, none for room families, k/n per instance, unknown bypasses stay unknown OK"

# ── 4. an undeclared or self-contradictory profile fails ─────────────────────
type Bare = ref object of Driver
method describe(d: Bare): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "bare", finality: finImmediate, threshold: 1)
block:
  let r = checkProfileConformance(Bare())
  doAssert not r.allPass(), "an undeclared profile must fail conformance"
  var p = newDriver("threshold", %*{"roster": roster, "k": 2}).profile()
  p.chain = "eip155:1"
  doAssert profileFailures(p, newDriver("threshold", %*{"roster": roster, "k": 2}).describe()).anyIt("room" in it),
    "a room family naming a chain must fail"
  var q = newDriver("safe", %*{"chainId": 1, "safe": SafeAddr, "owners": owners, "threshold": 2}).profile()
  q.locus = loAggregate; q.scheme = scAggregateThreshold
  doAssert profileFailures(q, newDriver("safe", %*{"chainId": 1, "safe": SafeAddr, "owners": owners, "threshold": 2}).describe()).len > 0,
    "an aggregate that reveals its signers must fail"
  var r2 = newDriver("frost", %*{"roster": roster, "k": 2}).profile()
  r2.rounds = 1
  doAssert profileFailures(r2, newDriver("frost", %*{"roster": roster, "k": 2}).describe()).anyIt("rounds" in it),
    "a profile whose rounds contradict describe() must fail"
  echo "4. an undeclared or self-contradictory profile fails conformance OK"

# ── 5. the stub's profile follows its descriptor (the probes randomize it) ──────
block:
  for fin in [finImmediate, finProbabilistic, finExternal]:
    for rounds in 1 .. 3:
      let d = newStubDriver(rounds = rounds, threshold = 2, finality = fin)
      doAssert checkProfileConformance(d).allPass(), "stub " & $fin & " r" & $rounds & ": " & $checkProfileConformance(d).failed()
  echo "5. the stub's profile is consistent under every finality and round count OK"

echo "profile_test: all OK"
