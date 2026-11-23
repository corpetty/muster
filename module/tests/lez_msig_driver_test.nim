## The lez-msig driver (epic exo-0d3), with no chain:
##   1. a disclosure re-derives the public PDA from (program, create key); another address, a
##      private placement, or a config whose threshold its approvers cannot reach is refused;
##   2. the effect is the proposal's exact bytes; canonicalize commits to its id under the
##      chain; a proposal for another multisig, another zone, or a non-proposer canonicalizes
##      to a sentinel and signRefusal says why;
##   3. a contribution counts only as a member's BIP-340 approval of THIS proposal, and is
##      named msig:<key>; in-app, the member's keystore signs with its approval key for this
##      multisig, and attests the room's record with the same key (verifyAttestation);
##   4. describe: the threshold as a count of approvals (weights included), one more when the
##      proposer cannot approve;
##   5. profile and manifest are declared and consistent; conformance is green.
## Needs the secp closure + libsodium.

import std/[json, options, sequtils, strutils]
import stint
import ../src/dcbor/dcbor
import ../src/crypto/keystore
import ../src/drivers/driver
import ../src/drivers/conformance
import ../src/drivers/manifest
import ../src/drivers/profile
import ../src/drivers/inapp
import ../src/drivers/lez_msig
import ../src/intents/materialization
import ../src/coordination/intent_events
import ../src/coordination/attest
import ../src/coordination/effect_summary
import ../src/lez/msig
import ../src/bitcoin/keys as btckeys

proc fill(x: byte): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 32: result[i] = x

const Chain = "lez:local"
let program = fill(0x11)
let createKey = fill(0x22)
let zone = fill(0x2e)
proc keystore(seed: byte): Keystore =
  var a, b: array[32, byte]
  for i in 0 ..< 32: (a[i] = seed; b[i] = seed xor 0x5a)
  newInMemoryKeystore(a, b)
let ks = @[keystore(1), keystore(2), keystore(3)]
let label = msigLabel(createKey)
let keys = ks.mapIt(it.lezMemberKey(label))
let a = multisigPublic(program, createKey)

proc cfg(k: uint32): MsigConfig =
  MsigConfig(members: keys.mapIt(MsigMember(key: it, roles: RoleAll, weight: 1)), threshold: k,
             timelockMs: 0, openExecution: true, actions: ActAll)

proc account(c: MsigConfig): LezMsigAccount =
  LezMsigAccount(chain: Chain, program: program, createKey: createKey, zone: zone, address: a,
                 accountId: Chain & ":" & hexOf(a), epoch: 0, config: c)

let drv = newLezMsigDriver(account(cfg(2)))

proc proposal(nonce: uint64, amount: uint64, proposer = keys[0]): MsigProposal =
  MsigProposal(multisig: a, zone: zone, epoch: 0, nonce: nonce,
               action: MsigAction(kind: akTransfer, to: fill(0x0e), amount: amount.u128),
               expiresMs: 9_000_000_000_000'u64, proposer: proposer)

proc approval(i: int, p: MsigProposal): Contribution =
  var m: array[32, byte]
  let am = approveMsg(proposalId(p))
  for j in 0 ..< 32: m[j] = am[j]
  Contribution(bytes: contributionOf(keys[i], ks[i].lezMemberSign(label, m)))

# ── 1. disclosure ─────────────────────────────────────────────────────────────
block:
  let good = configJsonOf(account(cfg(2)))
  let r = lezMsigAccountOf(Chain, hexOf(a), good)
  doAssert r.ok, r.detail
  doAssert r.account.accountId == Chain & ":" & hexOf(a) and r.account.config == cfg(2)
  doAssert not lezMsigAccountOf(Chain, hexOf(fill(9)), good).ok, "another address"
  let priv = parseJson(good)
  priv["placement"] = %"private"
  # a private multisig's address takes the group's keys to derive: it is taken as disclosed,
  # marked private, and its config still has to fit (exo-efa)
  let pr = lezMsigAccountOf(Chain, hexOf(fill(9)), $priv)
  doAssert pr.ok and pr.account.private and pr.account.address == fill(9), pr.detail
  doAssert newLezMsigDriver(pr.account).profile.family == LezMsigPrivateFamily
  doAssert newLezMsigDriver(pr.account).profile.revealsSigners == rvNever, "no approver on chain"
  priv["placement"] = %"shielded"
  doAssert not lezMsigAccountOf(Chain, hexOf(a), $priv).ok, "an unknown placement"
  doAssert not lezMsigAccountOf(Chain, hexOf(a), configJsonOf(account(cfg(4)))).ok, "4 of 3"
  echo "1. a disclosure re-derives the public PDA and checks its config OK"

# ── 2. the effect and its materialization ──────────────────────────────────────
block:
  let p = proposal(0, 400)
  let e = effectFromJson(lezMsigEffect(p))
  doAssert e.schemaId == LezMsigSchema and proposalOf(e) == p
  let m = canonicalize(drv, e)
  let v = decode(m.bytes)
  doAssert v.arr.len == 3 and v.arr[1].t == Chain and v.arr[2].b == proposalId(p), "the id, under the chain"
  doAssert canonicalize(drv, effectFromJson(lezMsigEffect(proposal(0, 401)))).bytes != m.bytes
  doAssert drv.signRefusal(e) == ""
  var other = p
  other.multisig = fill(9)
  doAssert "another multisig" in drv.signRefusal(effectFromJson(lezMsigEffect(other)))
  doAssert decode(canonicalize(drv, effectFromJson(lezMsigEffect(other))).bytes).arr.len == 2, "a sentinel"
  other = p
  other.zone = fill(8)
  doAssert "zone" in drv.signRefusal(effectFromJson(lezMsigEffect(other)))
  doAssert "not a member" in drv.signRefusal(effectFromJson(lezMsigEffect(proposal(0, 1, fill(7)))))
  var padded = parseJson(lezMsigEffect(p))
  padded["proposal"] = %(padded["proposal"].getStr() & "00")
  doAssert "not a lez-msig proposal" in drv.signRefusal(effectFromJson($padded)), "non-canonical bytes"
  # the card's line, read from the same bytes (RFP U.6)
  let sm = effectSummary(lezMsigEffect(p))
  doAssert sm.kind == "payment" and sm.amount == "0.0000004" and sm.unit == "LEZ" and sm.to == hexOf(fill(0x0e)), $sm
  doAssert "LEZ multisig payment" in sm.text and "proposal #0" in sm.text and "nonce" notin sm.text, sm.text
  doAssert effectSummary($padded).kind == "unknown", "bytes that do not decode are named, never guessed"
  echo "2. the effect is the proposal's bytes; canonicalize commits to its id; foreign ones refused OK"

# ── 3. contributions ───────────────────────────────────────────────────────────
block:
  let p = proposal(0, 400)
  let e = effectFromJson(lezMsigEffect(p))
  let m = canonicalize(drv, e)
  drv.expectMaterialization(m)
  doAssert drv.verifyContribution(approval(1, p), 1)
  doAssert identifyContributor(drv, m, approval(1, p)) == "msig:" & hexOf(keys[1])
  doAssert not drv.verifyContribution(approval(1, proposal(0, 401)), 1), "an approval of another proposal"
  let outsider = keystore(9)
  var om: array[32, byte]
  let am = approveMsg(proposalId(p))
  for j in 0 ..< 32: om[j] = am[j]
  doAssert not drv.verifyContribution(Contribution(bytes: contributionOf(outsider.lezMemberKey(label),
                                      outsider.lezMemberSign(label, om))), 1), "an outsider"
  doAssert not drv.verifyContribution(Contribution(bytes: @[1'u8, 2]), 1)
  # in-app: the member's approval key for THIS multisig, attesting with the same key
  let digest = attestationDigest(@[7'u8, 7, 7])
  let s = drv.signInApp(e, ks[2], digest)
  doAssert s.handled and s.keyRef == ""
  doAssert drv.verifyContribution(Contribution(bytes: s.contribution), 1)
  doAssert verifyAttestation("msig:" & hexOf(keys[2]), @[7'u8, 7, 7], hexOf(s.attestation))
  doAssert not verifyAttestation("msig:" & hexOf(keys[1]), @[7'u8, 7, 7], hexOf(s.attestation)), "another key"
  doAssert not verifyAttestation("msig:" & hexOf(keys[2]), @[7'u8, 7, 8], hexOf(s.attestation)), "another record"
  doAssert drv.mayContribute(e, @["msig:" & hexOf(keys[2])]) == elYes
  doAssert drv.mayContribute(e, @["msig:" & hexOf(outsider.lezMemberKey(label))]) == elNo
  doAssert ks[2].lezMemberKey(msigLabel(fill(0x23))) != keys[2], "one approval key per multisig"
  echo "3. an approval counts only for a member, for this proposal; in-app signs + attests with one key OK"

# ── 4. the threshold as a count ────────────────────────────────────────────────
block:
  doAssert drv.describe().threshold == 2
  var c = cfg(3)
  c.members[0].weight = 2
  doAssert newLezMsigDriver(account(c)).describe().threshold == 2, "a weight-2 member and one more reach 3"
  c = cfg(2)
  c.members[0].roles = RolePropose
  let d2 = newLezMsigDriver(account(c))
  doAssert d2.describeFor(effectFromJson(lezMsigEffect(proposal(0, 1)))).threshold == 3,
    "a proposer who cannot approve signs, and does not count"
  echo "4. the threshold counts weights and a non-approving proposer OK"

# ── 5. profile, manifest, conformance ──────────────────────────────────────────
block:
  let p = drv.profile()
  doAssert p.declared and p.family == LezMsigFamily and p.settlement == "lez"
  doAssert p.locus == loContract and p.scheme == scSharedBytes and p.binding == bdExplicit
  doAssert p.approverCost == acNone and p.expiry == exForced and p.k == 2 and p.n == 3
  doAssert profileFailures(p, drv.describe()).len == 0, $profileFailures(p, drv.describe())
  let e = effectFromJson(lezMsigEffect(proposal(0, 400)))
  let t = effectFromJson(lezMsigEffect(proposal(0, 999)))
  drv.expectMaterialization(canonicalize(drv, e))
  let conf = checkConformance(drv, e, t, approval(1, proposal(0, 400)))
  doAssert conf.allPass(), "conformance: " & $conf.failed()
  doAssert checkProfileConformance(drv).allPass(), $checkProfileConformance(drv).failed()
  let m = drv.manifest(e)
  doAssert m.declared and consistencyFailures(m).len == 0, $consistencyFailures(m)
  doAssert m.discloses.anyIt(it.field == "approvals" and it.to == obChainObserver), "the public posture shows approvals"
  echo "5. profile, manifest and conformance green OK"

# ── 6. a spend under a limit (exo-0d3.12) ─────────────────────────────────────
block:
  # limit 7: members 2 and 3 sign, 1 of them is enough, up to 500 per day
  var c = cfg(2)
  c.limits = @[MsigLimit(id: 7, signers: @[keys[1], keys[2]], threshold: 1, amount: 500.u128, periodMs: 86_400_000)]
  let d = newLezMsigDriver(account(c))
  let sp = MsigSpend(multisig: a, zone: zone, epoch: 0, limit: 7, nonce: 3, to: fill(0x0e), amount: 200.u128,
                     expiresMs: 9_000_000_000_000'u64)
  let e = effectFromJson(lezMsigSpendEffect(sp))
  doAssert e.schemaId == LezMsigSpendSchema and e.isSpend and msigSpendOf(e) == sp
  doAssert d.signRefusal(e) == ""
  doAssert d.describeFor(e).threshold == 1, "the limit's threshold, not the quorum's"
  let m = canonicalize(d, e)
  let v = decode(m.bytes)
  doAssert v.arr.len == 4 and v.arr[2].b == spendMsg(sp) and v.arr[3].u == 7, "the spend message and its limit"
  proc spendSig(i: int, s: MsigSpend): Contribution =
    var h: array[32, byte]
    let sm = spendMsg(s)
    for j in 0 ..< 32: h[j] = sm[j]
    Contribution(bytes: contributionOf(keys[i], ks[i].lezMemberSign(label, h)))
  doAssert d.identifyContributor(m, spendSig(1, sp)) == ContributorPrefix & hexOf(keys[1])
  doAssert d.identifyContributor(m, spendSig(0, sp)) == "", "member 1 is not the limit's signer"
  var other = sp
  other.amount = 201.u128
  doAssert d.identifyContributor(m, spendSig(2, other)) == "", "a signature over another spend"
  d.expectMaterialization(m)
  doAssert d.verifyContribution(spendSig(2, sp), 0) and not d.verifyContribution(spendSig(0, sp), 0)
  doAssert d.mayContribute(e, @[ContributorPrefix & hexOf(keys[1])]) == elYes
  doAssert d.mayContribute(e, @[ContributorPrefix & hexOf(keys[0])]) == elNo
  # in-app: the member's key among the limit's signers signs the spend message
  let ins = d.signInApp(e, ks[2], default(array[32, byte]))
  doAssert ins.handled and d.identifyContributor(m, Contribution(bytes: ins.contribution)) == ContributorPrefix & hexOf(keys[2])
  # refusals
  other = sp
  other.amount = 501.u128
  doAssert "over the limit" in d.signRefusal(effectFromJson(lezMsigSpendEffect(other)))
  doAssert decode(canonicalize(d, effectFromJson(lezMsigSpendEffect(other))).bytes).arr.len == 2, "a sentinel"
  other = sp
  other.limit = 8
  doAssert "no spending limit 8" in d.signRefusal(effectFromJson(lezMsigSpendEffect(other)))
  other = sp
  other.multisig = fill(9)
  doAssert "another multisig" in d.signRefusal(effectFromJson(lezMsigSpendEffect(other)))
  # a proposal through the same driver still verifies against the quorum
  let pe = effectFromJson(lezMsigEffect(proposal(0, 400)))
  let pm = canonicalize(d, pe)
  doAssert d.identifyContributor(pm, approval(0, proposal(0, 400))).len > 0
  doAssert d.describeFor(pe).threshold == 2
  let man = d.manifest(e)
  doAssert man.declared and consistencyFailures(man).len == 0 and man.agreement.threshold == 1
  doAssert man.touches.anyIt(hexOf(fill(0x0e)) in it.target), "the payee"
  doAssert d.profile.bypasses == @["spending-limit"]
  echo "6. a spend: the limit's signers sign its exact bytes, its threshold is the limit's, the quorum is not asked OK"

echo "lez_msig_driver_test: all passed"
