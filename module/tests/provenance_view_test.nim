## Enriched decision provenance (invariant 10, the investigable lineage) — pure.
## intentProvenance now carries a plain-language `what`, a concrete `detail` (the
## effect summary / round), and the `guarantee` that makes each input trustworthy,
## and names the account behind each approval.

import std/strutils
import ../src/coordination/intents
import ../src/drivers/driver
import ../src/crypto/curve25519
import ./probes/attested

# ── summarizeEffect: a human one-liner per effect kind ─────────────────────────
block:
  doAssert summarizeEffect("""{"to":"0x1111","value":1000,"nonce":0}""") == "pay 1000 to 0x1111"
  doAssert summarizeEffect("""{"effect":"statement","text":"ship it"}""").contains("ship it")
  doAssert summarizeEffect("""{"effect":"invoke","module":"vote","method":"cast","args":[]}""") ==
           "call vote.cast(…)"
  doAssert summarizeEffect("not json") == ""
  # a split reads in its asset's own decimals, never a raw base-unit count labelled as the
  # asset (the provenance line said "split 2000000000000000 ETH" until 2026-10-16)
  doAssert summarizeEffect("""{"effect":"split","total":"2000000000000000","asset":"ETH","shares":[{}]}""") ==
           "split 0.002 ETH: 1 person owes the creditor"
  doAssert summarizeEffect("""{"effect":"split","total":"150000","asset":"BTC","shares":[{},{}]}""") ==
           "split 0.0015 BTC: 2 people owe the creditor"
  doAssert summarizeEffect("""{"effect":"split","total":"2500000000","asset":"LEZ","shares":[{}]}""") ==
           "split 2.5 LEZ: 1 person owes the creditor"
  doAssert summarizeEffect("""{"effect":"split","total":"1000000","asset":"erc20:0x00000000000000000000000000000000000000aa","shares":[{}]}""") ==
           "split 1000000 base units of erc20:0x00000000000000000000000000000000000000aa: 1 person owes the creditor"
  echo "1. summarizeEffect renders each effect kind OK"

const effectJson = """{"to":"0x00000000000000000000000000000000DeaDBeef","value":42,"nonce":0}"""
let id = intentIdFor(effectJson, "x")
# The approvers are Ed25519 keys and each approval carries its signer's attestation over P,
# as the live path publishes it: the stub here is a room family, where an unattested
# approval counts for nothing (exo-af5).
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc edName(k: EncKeys): string =
  const d = "0123456789abcdef"
  result = "ed:"
  for x in k.identity().ed: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let aliceK = encFromSeed(seed(1))
let bobK = encFromSeed(seed(2))
let alice = edName(aliceK)
let bob = edName(bobK)
let stubFor: DriverFor = proc(kind: string): Driver = newStubDriver()
let events = withAttestations(@[
  policyDeclEvent(id, "x"),
  proposeEvent(id, effectJson),
  contributeEvent(id, alice, "aa", 1),
  contributeEvent(id, bob, "bb", 1),
  contributeEvent(id, alice, "aa", 1)],    # a duplicate — must fold once in the lineage
  stubFor, id, signers = [aliceK, bobK])

proc proposalOf(prov: seq[ProvItem]): ProvItem =
  for p in prov:
    if p.cls == icPeerMessage: return p
proc approvalsOf(prov: seq[ProvItem]): seq[ProvItem] =
  for p in prov:
    if p.cls == icContribution: result.add p
proc accounts(items: seq[ProvItem]): seq[string] =
  for p in items: result.add p.account

# ── accounts named, entries enriched ─────────────────────────
block:
  let named: DriverFor = proc(kind: string): Driver = newStubDriver()
  let prov = intentProvenance(events, named, id)
  doAssert prov.len == 3, "one proposal + two distinct approvals (duplicate folded), got " & $prov.len

  let p = prov.proposalOf()
  doAssert p.what == "the proposal"
  doAssert p.detail == "pay 42 to 0x00000000000000000000000000000000DeaDBeef",
           "the proposal's provenance carries the effect summary: " & p.detail
  doAssert p.guarantee.contains("sealed to the room"), "the proposal's guarantee is stated"

  let apps = prov.approvalsOf()
  doAssert apps.len == 2 and apps[0].what == "an approval"
  doAssert alice in apps.accounts() and bob in apps.accounts(), "the lineage names the signers"
  doAssert apps[0].attestation == "committed" and apps[1].attestation == "committed",
    "each approval is attested in this room"
  doAssert apps[0].guarantee.contains("recovers to a configured member"),
           "an approval's guarantee explains the verification"
  echo "2. enriched, accounts named, duplicate folded OK"

echo "provenance_view_test: all OK"
