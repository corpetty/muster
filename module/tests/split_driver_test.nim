## The split and the evm.split family (exo-a90.3; docs/design/split-the-bill.md §3–§4).
## One person fronted a bill; the effect names who owes how much and where to pay. This
## holds the driver to what the design promises:
##   * the effect has ONE spelling: canonical decimal amounts, shares sorted by who, no
##     duplicates, the creditor never a debtor, the shares never more than the total, the
##     chain the policy's — anything else is refused with its reason (invariants 1, 5);
##   * the threshold is how many the effect names (describeFor), and only a DEBTOR'S room
##     key agrees — not the creditor's, not a member the split does not name;
##   * each debtor is a part: settled by that debtor, confirmed by the creditor, and the
##     transfer that settles it is derived from the effect (invariant 1);
##   * the driver conforms (the standard every driver meets) and its profile is the new
##     "each" locus: no shared account, a CAIP-2 chain, settlement motivational;
##   * the room fold runs a split to final on the real driver;
##   * even shares round down and the creditor absorbs the remainder, visibly.
## Needs libsodium (Ed25519).

import std/[json, strutils, sequtils, algorithm, tables]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/drivers/profile
import ../src/drivers/kinds
import ../src/drivers/registry
import ../src/drivers/conformance
import ../src/drivers/split
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/accounts
import ../src/coordination/card_rows
import ../src/coordination/effect_summary

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc idOf(k: EncKeys): string = hx(k.identity().toBytes())      # the 128-hex room identity
proc edName(k: EncKeys): string = "ed:" & hx(k.identity().ed)   # how the driver names a party

let devon = encFromSeed(seed(1))     # fronted the bill
let ana = encFromSeed(seed(2))
let jb = encFromSeed(seed(3))
let you = encFromSeed(seed(4))
let outsider = encFromSeed(seed(9))  # in the room, not at dinner
const Chain = "eip155:31337"
const PayTo = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

proc sharesSorted(ws: seq[(EncKeys, string)]): JsonNode =
  var xs = ws.mapIt((idOf(it[0]), it[1]))
  xs.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  result = newJArray()
  for (w, a) in xs: result.add %*{"who": w, "amount": a}

proc splitJson(total = "1200000000000000000", shares = sharesSorted(@[(ana, "300000000000000000"),
               (jb, "300000000000000000"), (you, "300000000000000000")]), chain = Chain, asset = "ETH",
               creditor = idOf(devon), payTo = PayTo, memo = "Dinner at Tasca"): string =
  $(%*{"effect": "split", "chain": chain, "asset": asset, "total": total, "creditor": creditor,
       "payTo": payTo, "shares": shares, "memo": memo})

let roster = @[idOf(devon), idOf(ana), idOf(jb), idOf(you), idOf(outsider)]
let drv = newSplitDriver(EvmSplitFamily, Chain, roster)
let good = splitJson()
let e = effectFromJson(good)

# ── 1. the effect: schema, one spelling, the refusals ────────────────────────────
block:
  doAssert e.schemaId == "muster.effect.split.v1", e.schemaId
  let (sid, known) = effectSchema(good)
  doAssert known and sid == e.schemaId, "the split is a recognized schema (the card renders it)"
  doAssert drv.signRefusal(e) == "", "a well-formed split is not refused: " & drv.signRefusal(e)
  doAssert canonicalize(drv, e).bytes == canonicalize(drv, effectFromJson(good)).bytes, "deterministic"
  proc refusedFor(j: string, why: string) =
    let r = drv.signRefusal(effectFromJson(j))
    doAssert r.len > 0 and why in r, "expected a refusal naming '" & why & "', got '" & r & "' for " & j
    # and it canonicalizes to a sentinel no debtor signature can name
    let m = canonicalize(drv, effectFromJson(j))
    doAssert m.bytes != canonicalize(drv, e).bytes
  refusedFor(splitJson(total = "800000000000000000"), "more than the total")
  refusedFor(splitJson(shares = %*[{"who": idOf(ana), "amount": "1"}, {"who": idOf(ana), "amount": "1"}]), "sorted")
  var rev = sharesSorted(@[(ana, "1"), (jb, "1")])
  rev = %(@[rev[1], rev[0]])
  refusedFor(splitJson(shares = rev), "sorted")
  refusedFor(splitJson(shares = sharesSorted(@[(devon, "1"), (ana, "1")])), "creditor")
  refusedFor(splitJson(shares = sharesSorted(@[(ana, "030")])), "canonical")
  refusedFor(splitJson(shares = sharesSorted(@[(ana, "0")])), "more than zero")
  refusedFor(splitJson(shares = sharesSorted(@[(ana, "1.5")])), "canonical")
  refusedFor(splitJson(shares = sharesSorted(@[(ana, "-1")])), "canonical")
  refusedFor(splitJson(total = "0"), "more than zero")
  refusedFor(splitJson(shares = newJArray()), "no one")
  refusedFor(splitJson(payTo = "0x7099"), "payTo")
  refusedFor(splitJson(payTo = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"), "payTo")   # one spelling: lowercase
  refusedFor(splitJson(chain = "eip155:1"), "eip155:31337")
  refusedFor(splitJson(asset = "USDC"), "ETH")
  refusedFor(splitJson(memo = "x".repeat(281)), "memo")
  refusedFor(splitJson(creditor = "abcd"), "room identity")
  echo "1. the split has one spelling; every malformed variant is refused with its reason OK"

# ── 2. the threshold is everyone the effect names: each debtor and the creditor ───
block:
  doAssert drv.describe().threshold == 1
  doAssert describeFor(drv, e).threshold == 4, "three debtors and the creditor (exo-770)"
  let m = canonicalize(drv, e)
  drv.expectMaterialization(m)
  proc sig(k: EncKeys, bytes: seq[byte]): Contribution =
    let s = edSign(k, bytes)
    Contribution(bytes: @s)
  doAssert drv.verifyContribution(sig(ana, m.bytes), 1), "a debtor agrees"
  doAssert identifyContributor(drv, m, sig(ana, m.bytes)) == edName(ana)
  doAssert drv.verifyContribution(sig(devon, m.bytes), 1), "the creditor agrees too: their word that payTo is theirs"
  doAssert identifyContributor(drv, m, sig(devon, m.bytes)) == edName(devon)
  doAssert drv.agreesByProposing(e, idOf(devon)) and not drv.agreesByProposing(e, idOf(ana)),
           "only the creditor's own proposal carries their agreement"
  doAssert not drv.verifyContribution(sig(outsider, m.bytes), 1), "a member the split does not name"
  doAssert identifyContributor(drv, m, sig(outsider, m.bytes)) == ""
  let other = canonicalize(drv, effectFromJson(splitJson(memo = "Lunch")))
  doAssert not drv.verifyContribution(sig(ana, other.bytes), 1), "an agreement to another split"
  echo "2. describeFor = 3 debtors + the creditor; only a named party's room key agrees OK"

# ── 3. the parts: each debtor, settled by them, confirmed by the creditor ────────
block:
  let parts = drv.settlementParts(e)
  doAssert parts.len == 3 and sorted(parts) == sorted(@[edName(ana), edName(jb), edName(you)])
  doAssert drv.partAuthor(e, edName(ana), "settled") == idOf(ana)
  doAssert drv.partAuthor(e, edName(ana), "confirmed") == idOf(devon)
  doAssert drv.partAuthor(e, edName(outsider), "settled") == "", "not a part"
  doAssert drv.partAuthor(e, edName(ana), "refunded") == "", "an unknown step"
  let t = drv.partTransfer(e, edName(jb))
  doAssert t.ok and t.chain == Chain and t.asset == "ETH" and t.to == PayTo and
           t.amount == "300000000000000000", "the transfer is derived from the effect"
  doAssert not drv.partTransfer(e, edName(outsider)).ok
  doAssert not drv.partTransfer(effectFromJson(splitJson(total = "1")), edName(ana)).ok,
           "a malformed split derives no transfer"
  echo "3. parts: debtor settles, creditor confirms, the transfer is derived OK"

# ── 4. conformance: the same standard as every driver ────────────────────────────
block:
  let tampered = effectFromJson(splitJson(shares = sharesSorted(@[(ana, "300000000000000000"),
    (jb, "300000000000000000"), (you, "300000000000000001")])))
  let m = canonicalize(drv, e)
  let r = checkConformance(drv, e, tampered, Contribution(bytes: @(edSign(ana, m.bytes))))
  doAssert r.allPass(), "split driver must conform: failed " & $r.failed()
  let pr = checkProfileConformance(drv)
  doAssert pr.allPass(), "split profile must conform: failed " & $pr.failed()
  echo "4. the split driver conforms (", r.checks.len, " + ", pr.checks.len, " checks) OK"

# ── 5. manifest + profile + card rows: the each locus, told honestly ─────────────
block:
  let man = drv.manifest(e)
  doAssert man.declared and consistent(man, e), $consistencyFailures(man, e)
  var payTo, party, share = false
  for rq in man.requirements:
    if rq.party == rpProposer and rq.needs.class == mcAddress and rq.needs.field == "payTo": payTo = true
    if rq.kind == rqAuthority and rq.party == rpContributor: party = true
    if rq.kind == rqAsset and rq.party == rpPayer: share = true
  doAssert payTo and party and share,
           "payTo is proposer material; a party needs their room key; only a PAYER needs their share (exo-272)"
  # the creditor agrees (exo-770) but pays nothing: settlesAPart tells payers from signers
  doAssert drv.settlesAPart(e, @[edName(ana)]) == elYes, "a debtor settles a part"
  doAssert drv.settlesAPart(e, @[edName(devon)]) == elNo, "the creditor agrees, and pays nothing"
  doAssert drv.settlesAPart(e, @["ed:" & repeat("ab", 32)]) == elNo, "a stranger settles nothing"
  doAssert newStubDriver().settlesAPart(e, @[edName(ana)]) == elNo, "a whole-account driver has no parts"
  for f in ["payer", "payee", "amount"]:
    doAssert man.discloses.anyIt(it.field == f and it.to == obChainObserver), "EVM: " & f & " is public"
  doAssert man.touches.anyIt(it.target == Chain & ":" & PayTo and it.mode == tmWrite)
  let p = drv.profile()
  doAssert p.declared and p.family == EvmSplitFamily and p.locus == loEach and p.settlement == "evm"
  doAssert p.chain == Chain and p.account == "", "a CAIP-2 chain, no shared account"
  doAssert profileFailures(p, drv.describe()).len == 0, $profileFailures(p, drv.describe())
  # the each-locus rules bite: a profile that claims a shared account, or charges to agree, fails
  var bad = p
  bad.account = Chain & ":" & PayTo
  doAssert profileFailures(bad, drv.describe()).anyIt("shared account" in it)
  bad = p
  bad.approverCost = acPerVote
  doAssert profileFailures(bad, drv.describe()).len > 0
  let rows = cardRows(p)
  doAssert rows[0].credibility == "motivational" and "Nothing makes anyone pay" in rows[0].text,
           "settlement is motivational, and the card says so: " & rows[0].text
  doAssert rows[6].credibility == "exposed" and "link the group" in rows[6].text, rows[6].text
  echo "5. manifest, profile (locus each) and card rows tell the split honestly OK"

# ── 6. kinds + resolution: evm-split@<CAIP-2>, never a guess ─────────────────────
block:
  doAssert isKnownKind("evm-split") and kindInfo("evm-split").family == EvmSplitFamily
  doAssert "evm-split" in kindsFor("split")
  let build = proc(policy: string): Driver =
    let (k, chain) = splitPolicy(policy)
    if k == "evm-split": newSplitDriver(EvmSplitFamily, chain, roster) else: newUnsupportedDriver(policy)
  doAssert driverForPolicy("evm-split@eip155:31337", @[], build) of SplitDriver
  doAssert not driverForPolicy("evm-split", @[], build).supported(), "which chain? never guessed"
  doAssert not driverForPolicy("evm-split@lez:testnet", @[], build).supported(), "not an EVM chain"
  doAssert not driverForPolicy("evm-split@eip155:31337:0xabc", @[], build).supported(), "a chain, not an account"
  let viaRegistry = newDriver("evm-split", %*{"chain": Chain})
  doAssert viaRegistry.profile().family == EvmSplitFamily and viaRegistry.environment() == Chain
  echo "6. evm-split resolves only with a CAIP-2 eip155 chain OK"

# ── 7. the room fold: agree → pay → confirm → final, on the real driver ──────────
block:
  let policy = "evm-split@" & Chain
  let dfor: DriverFor = proc(k: string): Driver = drv
  let id = intentIdFor(good, policy)
  let m = canonicalize(drv, e)
  proc agree(k: EncKeys): Event =
    let s = hx(edSign(k, m.bytes))
    contributeEvent(id, contributorOf(drv, good, s), s)
  var evs = @[policyDeclEvent(id, policy), proposeEvent(id, good), agree(ana), agree(jb)]
  let sOut = hx(edSign(outsider, m.bytes))
  doAssert intentState(evs & @[contributeEvent(id, edName(outsider), sOut)], dfor, id) == "collecting",
           "two of three debtors; the outsider's agreement never counts in the fold"
  evs.add agree(you)
  doAssert intentState(evs, dfor, id) == "collecting", "every debtor agreed; the creditor has not (exo-770)"
  evs.add agree(devon)
  doAssert intentState(evs, dfor, id) == "executable", "everyone named agreed, the creditor too"
  for k in [ana, jb, you]:
    evs.add partEvent(id, edName(k), "settled", idOf(k), "0x" & hx(k.identity().ed)[0 ..< 8])
  evs.add partEvent(id, edName(ana), "settled", idOf(jb), "0xforged")          # jb cannot report for ana
  evs.add partEvent(id, edName(jb), "confirmed", idOf(ana), "0xself")          # only devon confirms
  doAssert intentState(evs, dfor, id) == "submitted"
  for k in [ana, jb, you]:
    evs.add partEvent(id, edName(k), "confirmed", idOf(devon), "0x" & hx(k.identity().ed)[0 ..< 8])
  doAssert intentState(evs, dfor, id) == "final", "every share confirmed by the creditor"
  var v: IntentView
  for x in reduceIntentViews(evs, dfor):
    if x.id == id: v = x
  doAssert v.threshold == 4 and v.approvals == 4 and v.parts.len == 3, "four agree; three pay"
  doAssert v.parts.allIt(it.confirmed and it.confirmedBy == idOf(devon))
  echo "7. the room fold runs a split to final on the real driver OK"

# ── 8. even shares: round down, the creditor absorbs the remainder ───────────────
block:
  let es = evenShares("1200000000000000000", idOf(devon), @[idOf(ana), idOf(jb), idOf(you), idOf(devon)])
  doAssert es.len == 3, "the creditor is never a debtor, even when listed"
  doAssert es.allIt(it.amount == "300000000000000000")
  doAssert es.mapIt(it.who) == sorted(es.mapIt(it.who)), "sorted: one spelling"
  let odd = evenShares("10", idOf(devon), @[idOf(ana), idOf(jb)])
  doAssert odd.allIt(it.amount == "3"), "10 among three people: each debtor owes 3; devon's own share is 4"
  let j = splitEffectJson(Chain, "ETH", "10", idOf(devon), PayTo, odd, "odd")
  doAssert drv.signRefusal(effectFromJson(j)) == "", "the composer's JSON is a valid split"
  doAssert intentIdFor(j, "p") == intentIdFor(splitEffectJson(Chain, "ETH", "10", idOf(devon), PayTo,
             reversed(odd), "odd"), "p"), "the composer sorts: the same split has one id"
  let s = effectSummary(good)
  doAssert s.kind == "split" and s.amount == "1200000000000000000" and "3 people" in s.text, s.text
  echo "8. even shares round down; the creditor absorbs the remainder; one id per split OK"

# ── 9. the history's words for a split: its own decimals, and people by name (exo-221) ──
block:
  let eth = splitEffectJson(Chain, "ETH", "600000000000000000", idOf(devon), PayTo,
                            evenShares("600000000000000000", idOf(devon), @[idOf(ana)]), "Taxi")
  let s = effectSummary(eth)
  doAssert s.amount == "600000000000000000" and s.unit == "wei", "the raw amount stays for the card: " & s.amount
  doAssert "0.6 ETH" in s.text and "wei" notin s.text, "the text reads in the asset's own decimals: " & s.text
  doAssert "1 person owes " in s.text, s.text
  let named = effectSummary(eth, proc(who: string): string = (if who == idOf(devon): "you" else: "Carol"))
  doAssert named.text.endsWith("1 person owes you"), "the creditor named as the card names them: " & named.text
  let lez = splitEffectJson("lez:testnet", "LEZ", "100", idOf(devon), "priv:" & "ab".repeat(32) & ":" & "02" & "cd".repeat(32),
                            evenShares("100", idOf(devon), @[idOf(ana)], distinctAmounts = true), "")
  doAssert "0.0000001 LEZ" in effectSummary(lez).text, effectSummary(lez).text
  echo "9. a split's summary: its own decimals, the creditor by name OK"

# ── 10. an ERC-20 split: its token named once, in one spelling (exo-5ab) ─────────
block:
  const Tok = "erc20:0x5fbdb2315678afecb367f032d93f642f64180aa3"
  let es = evenShares("900000", idOf(devon), @[idOf(ana), idOf(jb)])
  let e = splitEffectJson(Chain, Tok, "900000", idOf(devon), PayTo, es, "a token bill")
  doAssert drv.signRefusal(effectFromJson(e)) == "", drv.signRefusal(effectFromJson(e))
  for bad in ["USDC", "erc20:0x5FbDB2315678afecb367f032d93F642f64180aa3", "erc20:0x5fbdb2315678",
              "erc20:5fbdb2315678afecb367f032d93f642f64180aa3", "erc20:0x0000000000000000000000000000000000000000"]:
    let why = drv.signRefusal(effectFromJson(splitEffectJson(Chain, bad, "900000", idOf(devon), PayTo, es, "x")))
    doAssert "token" in why or "ETH" in why, bad & ": " & why
  let t = drv.partTransfer(effectFromJson(e), partName(idOf(ana)))
  doAssert t.ok and t.asset == Tok and t.to == PayTo and t.amount == "300000", $t
  var named = false
  for r in drv.manifest(effectFromJson(e)).requirements:
    if r.kind == rqAsset and Tok in $r: named = true
  doAssert named, "the manifest names the token a share is paid in"
  echo "10. an ERC-20 split: erc20:<token> in its one spelling; the share is paid in it OK"

# ── 11. the history's words for a token split: the token's own decimals and symbol ──
block:
  const Tok = "erc20:0x5fbdb2315678afecb367f032d93f642f64180aa3"
  let e = splitEffectJson(Chain, Tok, "900000", idOf(devon), PayTo,
                          evenShares("900000", idOf(devon), @[idOf(ana)]), "Team lunch")
  # told by the host what the token says about itself (display only): 0.9 MTD
  let told = effectSummary(e, nil, proc(asset: string): tuple[symbol: string, decimals: int] =
    (if asset == Tok: ("MTD", 6) else: ("", -1)))
  doAssert "0.9 MTD" in told.text and "erc20:" notin told.text, told.text
  # not told: base units, and the token named by a short address — never 18 decimals
  let blind = effectSummary(e)
  doAssert "900000 base units of token 0x5fbd" in blind.text and "0.0000" notin blind.text, blind.text
  doAssert told.amount == "900000", "the raw amount stays"
  echo "11. a token split's summary reads in the token's own decimals, or in base units OK"

echo "split_driver_test: all OK"
