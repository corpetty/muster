## One list of driver kinds (exo-a50.1.2, seam S2 of docs/design/multisig-landscape.md).
##
## Before this there were four lists that disagreed — registry.nim, the module's
## driverForKind, roomDriverKinds' founding set, and Room.qml's policiesForKind — and
## the module resolved an UNKNOWN policy to the Safe: a proposal under a kind this
## client does not have silently folded, verified and settled as a Safe transfer. That
## is a guess, and the design's rule is "shown, never guessed". Held here:
##   1. drivers/kinds.nim is the one list: every kind builds through the registry and
##      declares exactly the family the list names, which the family registry calls
##      built/partial;
##   2. the founding set and the proposal-kind mapping (what the composer offers) are
##      read from that list, and add-driver can only admit a kind on it;
##   3. an unknown kind REFUSES: the registry raises, and the resolver hands back an
##      UnsupportedDriver that verifies nothing, declares nothing, never lets an intent
##      reach executable — even under contributions a Safe would accept — and the live
##      contribute path refuses to sign it, publishing nothing.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, os, sequtils, strutils]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/manifest
import ../src/drivers/registry
import ../src/drivers/kinds
import ../src/crypto/curve25519
import ./probes/live_room

const RegistryPath = currentSourcePath().parentDir() / ".." / ".." / "contracts" / "families" / "registry.json"
let reg = parseJson(readFile(RegistryPath))
proc status(family: string): string =
  for f in reg["families"]:
    if f["id"].getStr() == family: return f["muster"]["status"].getStr()
  ""

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc edHex(k: Ed25519Pub): string =
  const d = "0123456789abcdef"
  result = "0x"
  for b in k: (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])
let roster = @[encFromSeed(seed(1)).identity().ed, encFromSeed(seed(2)).identity().ed,
               encFromSeed(seed(3)).identity().ed]
proc configFor(kind: string): JsonNode =
  case kind
  of "safe": %*{"chainId": 31337, "safe": SafeAddr, "owners": ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"], "threshold": 1}
  of "eip191": %*{"signers": ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"], "threshold": 1}
  of "btc-p2wsh", "btc-tapscript":
    %*{"network": "regtest", "k": 2, "keys": ["0307b8ae49ac90a048e9b53357a2354b3334e9c8bee813ecb98e99a7e07e8c3ba3",
                                            "03b28f0c28bfab54554ae8c658ac5c3e0ce6e79ad336331f78c428dd43eea8449b"]}
  of "lez-multisig":
    %*{"chain": "lez:local", "pda": "lee-v0.2", "program": repeat("aa", 32), "createKey": repeat("0b", 32),
       "threshold": 2, "members": [repeat("01", 32), repeat("02", 32), repeat("03", 32)]}
  of "btc-frost": %*{"network": "regtest", "recovery": frostTestRecoveryHex()}
  else: %*{"roster": roster.mapIt(edHex(it)), "k": 2}

# ── 1. the one list builds, and each kind is the family it says it is ─────────
block:
  doAssert Kinds.len > 0
  var seen: seq[string]
  for k in Kinds:
    doAssert k.kind notin seen, "duplicate kind " & k.kind
    seen.add k.kind
    let d = newDriver(k.kind, configFor(k.kind))
    doAssert d.profile().family == k.family,
      k.kind & " builds a " & d.profile().family & " driver, the list says " & k.family
    doAssert status(k.family) in ["built", "partial"],
      k.kind & "'s family " & k.family & " is " & status(k.family) & " in the registry"
    doAssert k.composes.len > 0 and k.composes.allIt(it in ["payment", "statement", "action"]),
      k.kind & " must say which proposals it serves"
    doAssert k.label.len > 0
  let u = newDriver("unanimous", configFor("unanimous"))
  doAssert u.describe().threshold == roster.len, "unanimous is the k = n threshold"
  echo "1. every kind on the one list builds and declares the family the list names OK"

# ── 2. founding set + the composer's mapping come from the list ───────────────
block:
  doAssert foundingKinds() == @["safe", "threshold", "frost", "invoke", "eip191", "btc-p2wsh", "btc-tapscript",
                               "lez-multisig", "btc-frost"], $foundingKinds()
  doAssert "unanimous" notin foundingKinds(), "unanimous is admitted by proposal, not founded"
  doAssert kindsFor("payment") == @["safe", "btc-p2wsh", "btc-tapscript", "lez-multisig", "btc-frost"], $kindsFor("payment")
  doAssert kindsFor("action") == @["invoke"], $kindsFor("action")
  doAssert kindsFor("statement") == @["threshold", "frost", "eip191", "unanimous"], $kindsFor("statement")
  let j = kindsJson(@["safe", "threshold"])
  doAssert j.len == Kinds.len
  for o in j:
    doAssert o["admitted"].getBool() == (o["kind"].getStr() in ["safe", "threshold"])
    doAssert o.hasKey("family") and o.hasKey("label") and o.hasKey("composes") and o.hasKey("founding")
  # add-driver admits only a kind on the list (a room cannot grant itself a driver
  # this client does not have — it would fold as unsupported forever)
  let thr = newDriver("threshold", configFor("threshold"))
  let foldDrv: DriverFor = proc(kind: string): Driver = thr
  let sign = proc(n: byte, id, eff: string): string =
    let m = canonicalize(thr, effectFromJson(eff))
    const d = "0123456789abcdef"
    for b in edSign(encFromSeed(seed(n)), m.bytes): (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])
  for (kind, admitted) in [("unanimous", true), ("btc.psbt-from-the-future", false)]:
    let eff = """{"effect":"add-driver","kind":"""" & kind & """"}"""
    let id = intentIdFor(eff, "threshold")
    let ev = @[proposeEvent(id, eff), contributeEvent(id, "A", sign(1, id, eff)),
               contributeEvent(id, "B", sign(2, id, eff))]
    doAssert intentState(ev, foldDrv, id) == "executable"
    doAssert (kind in roomDriverKinds(ev, foldDrv)) == admitted,
      kind & (if admitted: " must be admitted" else: " is not a kind this client has — admitting it is a guess")
  echo "2. the founding set, the composer's mapping and add-driver all read the one list OK"

# ── 3. an unknown kind refuses — never a silent Safe ───────────────────────────
block:
  var raised = false
  try: discard newDriver("squads", %*{})
  except RegistryError: raised = true
  doAssert raised, "the registry refuses a kind it does not have"
  doAssert not isKnownKind("squads") and isKnownKind("safe")
  let u = resolveKind("squads", proc(kind: string): Driver = newDriver(kind, configFor(kind)))
  doAssert u of UnsupportedDriver
  doAssert not u.profile().declared and not u.manifest(Effect()).declared
  doAssert not u.verifyContribution(Contribution(bytes: newSeq[byte](65)), 1)
  let known = resolveKind("threshold", proc(kind: string): Driver = newDriver(kind, configFor(kind)))
  doAssert known.profile().family == "room.threshold"
  # the fold: an intent recorded under an unknown kind, carrying two contributions a
  # Safe would accept, never reaches executable — it is not treated as a Safe transfer
  var r = newRoom("/muster/1/kinds-unknown/proto")
  let resolver: DriverFor = proc(kind: string): Driver =
    resolveKind(kind, proc(k: string): Driver = liveDriverFor(k))
  # a Safe effect whose inputs are accounted for (invariant 10: an in-app approval
  # refuses unaccountable inputs), exactly as the live probes build one
  let eff = effectFor("safe", 1, "\"sources\":{\"value\":\"read\",\"nonce\":\"read\"}")
  let asSafe = liveProposeIntent(r.alice, aliceKs, resolver, "safe", eff, int64(Now), 1,
                                 account = SafeAddr, ttlSec = Ttl)
  r.alice.publish(readEvent(asSafe, "value", "rpc://probe", "1"))
  r.alice.publish(readEvent(asSafe, "nonce", "rpc://probe", "0"))
  let st = liveContribute(r.alice, aliceKs, resolver, asSafe, "", "", bindCtx(), Now)
  doAssert st in ["collecting", "proposed"], "a Safe owner's in-app approval under the known kind: " & st
  let sigs = r.alice.log.allEvents().filterIt(it.key.startsWith("intent/" & asSafe & "/sig/"))
  doAssert sigs.len == 1
  let odd = intentIdFor(eff, "squads")
  r.alice.publish(policyDeclEvent(odd, "squads"))
  r.alice.publish(proposeEvent(odd, eff))
  let parts = sigs[0].key.split('/')
  r.alice.publish(contributeEvent(odd, parts[3], sigs[0].value))
  doAssert intentState(r.alice.log.allEvents(), resolver, odd) notin ["executable", "submitted", "final"],
    "a Safe owner's signature must not count toward an intent under a kind this client lacks"
  # the live path refuses to sign it and publishes nothing
  let before = r.alice.log.allEvents().len
  doAssert liveContribute(r.alice, aliceKs, resolver, odd, "", "", bindCtx(), Now) == "unsupported-driver"
  doAssert r.alice.log.allEvents().len == before, "a refused approval publishes nothing"
  doAssert liveProposeIntent(r.alice, aliceKs, resolver, "squads", eff, int64(Now), 2,
                             account = SafeAddr, ttlSec = Ttl) == "unsupported-driver",
    "proposing under a kind this client lacks is refused"
  echo "3. an unknown kind refuses: registry raises, the fold never counts it, the live path signs nothing OK"

echo "kinds_test: all OK"
