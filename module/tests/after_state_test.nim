## `after` never reaches state (C2, exo-525b; docs/design/causal-parents.md §3, §6 C2).
## A room log — a proposal with its policy, context and read, approvals and their
## attestation, a split paid in parts, an author-signed message, an admission — has every
## event's `after` stripped, then rewritten at random (forward references and
## contradictions included). Nothing a fold or a signing path derives may change:
## the state digest, the intent views, the flow, provenance, activity, the provenance
## record P each attestation signs, an approval's parents, the log proof, and which
## author-signed events verify. Stub + parts drivers; the message is really signed.

import std/[json, random, sequtils, strutils, tables, algorithm]
import ./fixtures/parts_driver
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/drivers/driver
import ../src/log/log
import ../src/log/proof
import ../src/intents/signing_payload
import ../src/coordination/intents
import ../src/coordination/flow
import ../src/coordination/attest
import ../src/coordination/authorship

proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc secret(h: string): array[32, byte] = (for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1])))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

const room = "/muster/1/after-state/proto"
let ks = newInMemoryKeystore(secret("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let alice = hex(ks.encIdentity().toBytes())
let bob = "b0b".repeat(4)

let stub: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 1, finality = finExternal, verifyResult = true)
let pdrv = PartsDriver()
let both: DriverFor = proc(kind: string): Driver = (if kind == "parts": Driver(pdrv) else: stub(kind))

let effectJson = """{"to":"0xdeadbeef","value":7}"""
let idA = intentIdFor(effectJson)
let ctx = SigningContext(environment: "eip155:1", account: "0xsafe", expiry: 2_000_000_000'u64)
let pEffect = partsEffect([alice, bob], "carol")
let idB = intentIdFor(pEffect, "parts")
let sig = contributeEvent(idA, "0xkey", "sa")
let base = chain(@[
  signAuthored(ks, room, newMessageEvent(alice, 1, "hello", 1)[1]),
  # the context and read are author-bearing, and the context counts only as a proposer's
  # (exo-ea8): alice's claim, then her context and read
  proposeEvent(idA, effectJson), proposerEvent(idA, alice), contextEvent(idA, ctx, author = alice),
  readEvent(idA, "nonce", "rpc", "7", author = alice),
  sig, attestEvent(idA, "0xkey", 1, "00"),
  membershipEvent(1, "ca7".repeat(4)),
  submitEvent(idA), finalEvent(idA),
  policyDeclEvent(idB, "parts"), proposeEvent(idB, pEffect),
  contributeEvent(idB, alice, hexName(alice)), contributeEvent(idB, bob, hexName(bob)),
  partEvent(idB, alice, "settled", alice, "0xa"), partEvent(idB, alice, "confirmed", "carol", "0xa")])

proc derived(evs: seq[Event]): seq[string] =
  ## everything a fold or a signing path derives from the log, as text
  result.add reduce(evs).stateDigest
  result.add $reduceIntentViews(evs, both)
  result.add $reduceFlow(evs, both, @[alice, bob]).toJson()
  result.add $logProvenance(evs, both)
  result.add $reduceActivity(evs, both)
  for id in [idA, idB]:
    result.add hex(attestationPayload(evs, both, id))
    result.add $intentInputs(evs, both, id)
    result.add $approvalParents(evs, both, id)
  result.add proofDigest(buildProof(evs))
  result.add $authenticEvents(evs, room).mapIt(eventId(it)).sorted()   # it keeps input order

let want = derived(base)
doAssert hex(attestationPayload(base, both, idA)).len > 0, "the fixture must have a P to compare"

block:
  let stripped = base.mapIt(Event(parents: it.parents, key: it.key, value: it.value))
  doAssert derived(stripped) == want
  echo "1. stripping after changes nothing a fold or signing path derives OK"

block:
  var r = initRand(5)
  let ids = base.mapIt(eventId(it))
  for trial in 0 ..< 25:
    var rewritten: seq[Event]
    for e in base:
      var x = e
      x.after = @[]
      for _ in 0 .. r.rand(3): x.after.add ids[r.rand(ids.len - 1)]   # forward refs, self refs, contradictions
      rewritten.add x
    r.shuffle(rewritten)
    let got = derived(rewritten)
    for i in 0 ..< want.len:
      if got[i] != want[i]: echo "DIFF at ", i, "\n  want: ", want[i][0 ..< min(300, want[i].len)], "\n  got:  ", got[i][0 ..< min(300, got[i].len)]
    doAssert got == want, "trial " & $trial
  echo "2. any rewrite of after, in any order, changes nothing a fold or signing path derives OK"

block:
  # an author-signed event still verifies when only its after differs: the claim signs
  # parents, never after, so stamping after at publish cannot break a signature
  let m = base[0]
  var m2 = m
  m2.after = @[eventId(base[3])]
  doAssert authenticEvents(@[m], room).len == 1 and authenticEvents(@[m2], room).len == 1
  echo "3. an author signature does not cover after OK"

echo "after_state_test: all OK"
