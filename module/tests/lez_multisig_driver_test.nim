## The vote-locus driver for the LEZ multisig program (exo-6cbe, Phase C3), family
## lez.multisig-program: behind the same Driver seam as the Safe and the Bitcoin
## families, but the approvals are the members' OWN on-chain transactions.
##   1. an account is disclosed WITH its config (program, create_key, PDA scheme); the
##      state address must be the PDA the config derives — a disclosure whose address does
##      not commit to its config, or that has none, is refused, never trusted; the fold
##      keeps the config and flags members who disclose a different one;
##   2. the kind is on the one list and account-bound; a disclosed account resolves to the
##      driver, an unsupported disclosure to nothing;
##   3. the effect is a POINTER — proposal #i — plus the content the room reviews there;
##      canonicalize commits to both, and every field changes the bytes (inv 1);
##   4. a contribution is a vote receipt naming the on-chain voter and WHAT they voted
##      for (the materialization); it verifies only for a member of the account and only
##      for this intent's pointer; the contributor is named "lez:<account>";
##   5. S5 — the pointer's content is re-read: reads(effect) names the proposal, and
##      checkRead refuses on-chain bytes that differ in any field from what the room
##      reviewed, or a proposal no longer active, or bytes that do not decode;
##   6. the profile is the registry's lez.multisig-program (vote locus, own transaction,
##      pointer, binding none, per-vote cost), it passes the conformance suite, and the
##      manifest says every approval is seen by the chain;
##   7. the chain check: the state read from the chain decides verified / disagrees /
##      unknown for a disclosure.
## Needs the secp closure + libsodium (conformance) — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/hashing/sha256
import ../src/log/log
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/profile
import ../src/drivers/manifest
import ../src/drivers/conformance
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/coordination/intent_events
import ../src/coordination/accounts

proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
proc hx(b: seq[byte]): string = (for x in b: result.add toLowerAscii(toHex(x, 2)))
let program = id32("program")
let K = id32("create-key")
let (A, B, C, D) = (id32("a"), id32("b"), id32("c"), id32("d"))
const Chain = "lez:local"
let state = statePda(psLee02, program, K)
let config = $(%*{"program": hx(program), "createKey": hx(K), "pda": "lee-v0.2"})

proc disclosed(address = hx(state), cfg = config, threshold = 2, members = @[A, B, C]): RoomAccount =
  RoomAccount(family: LezMultisigFamily, chain: Chain, address: address, label: "Treasury",
              signers: members.mapIt(hx(it)), threshold: threshold, config: cfg)

# ── 1. disclosure with config ──────────────────────────────────────────────────
block:
  let ok = lezMultisigAccountOf(disclosed())
  doAssert ok.ok and ok.account.statePda == state and ok.account.program == program and ok.account.createKey == K
  doAssert ok.account.members == @[A, B, C] and ok.account.threshold == 2 and ok.account.scheme == psLee02
  doAssert ok.account.accountId == Chain & ":" & hx(state)
  doAssert not lezMultisigAccountOf(disclosed(address = hx(id32("elsewhere")))).ok, "the address must be the config's PDA"
  let nssa = $(%*{"program": hx(program), "createKey": hx(K), "pda": "nssa-v0.2"})
  doAssert not lezMultisigAccountOf(disclosed(cfg = nssa)).ok, "the same config under the other scheme is another address"
  doAssert not lezMultisigAccountOf(disclosed(cfg = "")).ok, "no config: nothing to derive from"
  doAssert not lezMultisigAccountOf(disclosed(threshold = 4)).ok, "k above n"
  var evs = @[accountDiscloseEvent(disclosed(), "alice"),
              accountDiscloseEvent(disclosed(cfg = $(%*{"program": hx(program), "createKey": hx(id32("other")),
                                                         "pda": "lee-v0.2"})), "bob")]
  let folded = reduceAccounts(evs)
  doAssert folded.len == 1 and folded[0].config == config and folded[0].conflict, "first wins; a different config is a conflict"
  echo "1. a disclosure carries its config; the address must be the PDA it derives OK"

# ── 2. the kind, the policy ────────────────────────────────────────────────────
let acctRA = reduceAccounts(@[accountDiscloseEvent(disclosed(), "alice")])[0]
block:
  doAssert isKnownKind("lez-multisig") and kindNeedsAccount("lez-multisig")
  doAssert kindInfo("lez-multisig").family == LezMultisigFamily
  let room = proc(k: string): Driver = newUnsupportedDriver(k)
  let d = driverForPolicy(qualify("lez-multisig", acctRA.id), @[acctRA], room)
  doAssert d of LezMultisigDriver and d.supported()
  let badRA = reduceAccounts(@[accountDiscloseEvent(disclosed(address = hx(id32("x"))), "alice")])
  doAssert not driverForPolicy(qualify("lez-multisig", badRA[0].id), badRA, room).supported(),
    "a disclosure that does not commit to its config resolves to nothing"
  doAssert not driverForPolicy("lez-multisig", @[acctRA], room).supported(), "which account? never guessed"
  echo "2. the kind is account-bound; a disclosed account resolves to the driver OK"

let drv = newLezMultisigDriver(lezMultisigAccountOf(disclosed()).account)
let act = LezAction(target: id32("token"), instruction: @[1'u32, 500, 0], accounts: @[id32("vault"), id32("to")],
                    pdaSeeds: @[vaultSeed(K)], authorized: @[0'u8])

# ── 3. the pointer effect ──────────────────────────────────────────────────────
block:
  let e = effectFromJson(lezProposalEffect(1, act))
  doAssert e.schemaId == "muster.effect.lez-multisig-proposal.v1" and effectSchema(lezProposalEffect(1, act)).known
  let (idx, back) = lezActionOf(e)
  doAssert idx == 1 and back.target == act.target and back.instruction == act.instruction and
           back.accounts == act.accounts and back.pdaSeeds == act.pdaSeeds and back.authorized == act.authorized
  let m = canonicalize(drv, e).bytes
  var variants = @[lezProposalEffect(2, act)]
  var a2 = act; a2.target = id32("other"); variants.add lezProposalEffect(1, a2)
  var a3 = act; a3.instruction = @[1'u32, 501, 0]; variants.add lezProposalEffect(1, a3)
  var a4 = act; a4.accounts = @[id32("vault"), id32("someone-else")]; variants.add lezProposalEffect(1, a4)
  var a5 = act; a5.pdaSeeds = @[]; variants.add lezProposalEffect(1, a5)
  var a6 = act; a6.authorized = @[]; variants.add lezProposalEffect(1, a6)
  for v in variants:
    doAssert canonicalize(drv, effectFromJson(v)).bytes != m, "every field reaches the bytes: " & v
  let other = newLezMultisigDriver(lezMultisigAccountOf(disclosed(cfg = $(%*{"program": hx(program),
    "createKey": hx(id32("k2")), "pda": "lee-v0.2"}), address = hx(statePda(psLee02, program, id32("k2"))))).account)
  doAssert canonicalize(other, e).bytes != m, "the account is in the bytes too"
  echo "3. the effect is a pointer plus its content; every field reaches the signed bytes OK"

# ── 4. vote receipts ───────────────────────────────────────────────────────────
block:
  let e = effectFromJson(lezProposalEffect(1, act))
  let m = canonicalize(drv, e)
  let r = voteReceipt(B, 1, "ab".repeat(32), m)
  doAssert identifyContributor(drv, m, r) == "lez:" & hx(B)
  drv.expectMaterialization(m)
  doAssert drv.verifyContribution(r, 1)
  doAssert not drv.verifyContribution(voteReceipt(D, 1, "ab".repeat(32), m), 1), "not a member"
  let m2 = canonicalize(drv, effectFromJson(lezProposalEffect(2, act)))
  doAssert not drv.verifyContribution(voteReceipt(B, 2, "ab".repeat(32), m2), 1), "a vote for another pointer"
  doAssert identifyContributor(drv, m2, r) == "", "a receipt names what it voted for"
  doAssert not drv.verifyContribution(Contribution(bytes: @[1'u8, 2, 3]), 1)
  echo "4. a vote receipt counts only for a member and only for this pointer; named lez:<account> OK"

# ── 5. S5: the pointer's content, re-read ──────────────────────────────────────
block:
  let e = effectFromJson(lezProposalEffect(1, act))
  doAssert drv.reads(e) == @["proposal"]
  let good = newProposal(1, A, K, act)
  doAssert drv.checkRead(e, "proposal", encodeProposal(good)) == ""
  var withVotes = good
  discard withVotes.approve(B)
  doAssert drv.checkRead(e, "proposal", encodeProposal(withVotes)) == "", "votes are not content"
  proc refusal(p: Proposal): string = drv.checkRead(e, "proposal", encodeProposal(p))
  var x = good; x.index = 2; doAssert "index" in refusal(x)
  x = good; x.createKey = id32("k2"); doAssert "multisig" in refusal(x)
  x = good; x.action.target = id32("evil"); doAssert "target" in refusal(x)
  x = good; x.action.instruction = @[1'u32, 9000, 0]; doAssert "instruction" in refusal(x)
  x = good; x.action.accounts = @[]; x.action.accountCount = 3; doAssert "accounts" in refusal(x)
  x = good; x.action.pdaSeeds = @[]; doAssert "seeds" in refusal(x)
  x = good; x.action.authorized = @[0'u8, 1]; doAssert "authorized" in refusal(x)
  x = good; x.status = psExecuted; doAssert "executed" in refusal(x)
  x = newConfigProposal(1, A, K, ConfigAction(kind: caAddMember, member: D)); doAssert "config" in refusal(x)
  doAssert "decode" in drv.checkRead(e, "proposal", @[1'u8, 2, 3])
  doAssert drv.checkRead(e, "something-else", @[]) != "", "an undeclared read is refused"
  echo "5. S5: on-chain content that differs in any field, or a closed proposal, is refused OK"

# ── 6. profile, conformance, manifest ──────────────────────────────────────────
block:
  let p = drv.profile()
  doAssert p.declared and p.family == LezMultisigFamily and p.settlement == "lez"
  doAssert p.locus == loVote and p.scheme == scOwnTransaction and p.commits == cmPointer and p.binding == bdNone
  doAssert p.approverCost == acPerVote and p.revealsSigners == rvPerApproval and p.maturity == maDemo
  doAssert p.chain == Chain and p.account == Chain & ":" & hx(state) and p.k == 2 and p.n == 3
  doAssert profileFailures(p).len == 0, $profileFailures(p)
  let conf = checkConformance(drv)
  doAssert conf.allPass(), "conformance: " & $conf.failed()
  let m = drv.manifest(effectFromJson(lezProposalEffect(1, act)))
  doAssert m.declared and consistencyFailures(m).len == 0, $consistencyFailures(m)
  doAssert m.requirements.anyIt(it.kind == rqEnvironment and it.name == Chain)
  doAssert m.requirements.anyIt(it.kind == rqAuthority and it.party == rpContributor)
  doAssert m.discloses.anyIt(it.field == "approvals" and it.to == obChainObserver), "every approval is public"
  echo "6. profile = the registry's vote family; conformance green; the manifest says approvals are public OK"

# ── 7. the chain check ─────────────────────────────────────────────────────────
block:
  let chain = newFakeLezMultisig(Chain, psLee02, program, feePerTx = 0)
  doAssert checkAccount(acctRA, lezChainView(chain, acctRA)).status == acUnknown, "not on chain yet: unknown"
  doAssert chain.submit(A, createOp(K, 2, @[A, B, C])).ok
  doAssert checkAccount(acctRA, lezChainView(chain, acctRA)).status == acVerified
  let wrong = disclosed(threshold = 3)
  doAssert checkAccount(wrong, lezChainView(chain, wrong)).status == acDisagrees
  echo "7. the chain decides: verified / disagrees / unknown OK"

echo "lez_multisig_driver_test: the vote-locus driver — pointer, receipts, S5 re-reads, the registry's profile — all OK"
