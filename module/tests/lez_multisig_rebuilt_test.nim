## The rebuilt LEZ multisig program (exo-3c9): lez-multisig ported to SPEL v0.7.0 / LEZ v0.2.4
## — the line the live testnet runs — with the lez-multisig#40 fix (#41) in: a proposal
## COMMITS its target accounts and execute binds them. Muster's model follows it as a
## second, named layout; the published program's count-only layout stays decodable.
##   1. layout: in the account-ids layout the proposal carries target_account_ids (a u32
##      length + 32 bytes each) right after target_account_count; exact bytes, round trip;
##      the count-only layout is unchanged;
##   2. the chain model under the account-ids layout: a proposal whose ids do not match its
##      count is refused with the program's message; an executor who substitutes a target
##      account is refused ("Target account i does not match the approved proposal"); the
##      approved accounts execute — while under the count-only layout the substitution
##      still goes through (lez-multisig#40, what the card warns of there);
##   3. the driver: an account whose config names the account-ids layout checks the
##      target accounts on the S5 re-read, and its card names no way around the rule (the
##      "where" row is imperative); a count-only account keeps naming #40;
##   4. in the room: propose on chain, vote, settle — Executed with exactly the reviewed
##      accounts; a pointer whose on-chain accounts differ is refused before any vote;
##   5. the REAL chain: accounts read back from the rebuilt program running on a LEZ v0.2.4
##      sequencer (vectors/lez-multisig-v024, captured after lez-multisig's own e2e passed):
##      muster decodes the state and both proposals under the account-ids layout, re-encodes
##      them byte for byte, and derives the state, proposal and vault PDAs the chain used —
##      `psLee02` over the image id.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, strutils, sequtils, os]
import ../src/hashing/sha256
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/bitcoin/tx                # toHex / hexToBytes
import ../src/wallet/types
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, vote, accounts, card_rows]
import ./probes/live_room

proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
proc b32(x: byte): seq[byte] = newSeqWith(32, x)
proc le32(x: uint32): seq[byte] = @[byte(x and 0xff), byte((x shr 8) and 0xff), byte((x shr 16) and 0xff), byte(x shr 24)]
proc le64(x: uint64): seq[byte] =
  for i in 0 ..< 8: result.add byte((x shr uint64(8*i)) and 0xff)

let (A, B, C) = (id32("ra"), id32("rb"), id32("rc"))
let pay = id32("r-pay")
let program = id32("rebuilt-program")
let K = id32("rebuilt-room")
const Chain = "lez:local"

# ── 1. the account-ids layout ──────────────────────────────────────────────────
block:
  let K7 = b32(7)
  let prog = toSeq(0'u8 .. 31'u8)
  let p = newProposal(1, b32(1), K7, LezAction(target: prog, instruction: @[5'u32],
                      accounts: @[b32(8), b32(9)], pdaSeeds: @[b32(6)], authorized: @[0'u8]))
  let bytes = encodeProposal(p, plAccountIds)
  let want = le64(1) & b32(1) & K7 & prog & le32(1) & le32(5) & @[2'u8] &
             le32(2) & b32(8) & b32(9) &                 # target_account_ids
             le32(1) & b32(6) & le32(1) & @[0'u8] &
             le32(1) & b32(1) & le32(0) & @[0'u8] & @[0'u8]
  doAssert bytes == want, "borsh: " & $bytes.len & " vs " & $want.len
  let back = decodeProposal(bytes, plAccountIds)
  doAssert back.action.accounts == @[b32(8), b32(9)] and back.action.accountCount == 2
  doAssert encodeProposal(p) == encodeProposal(p, plCountOnly), "count-only stays the default"
  doAssert encodeProposal(p, plCountOnly).len == bytes.len - 4 - 64
  doAssert $plAccountIds == "account-ids" and parseProposalLayout("count-only") == plCountOnly
  echo "1. the account-ids layout: target_account_ids after the count; count-only unchanged OK"

# ── 2. the chain model ─────────────────────────────────────────────────────────
let act = LezAction(target: id32("token"), instruction: @[1'u32, 77, 0], accounts: @[id32("vault"), id32("to")],
                    pdaSeeds: @[vaultSeed(K)], authorized: @[0'u8])
block:
  let c = newFakeLezMultisig(Chain, psLee02, program, feePerTx = 0, layout = plAccountIds)
  doAssert c.submit(A, createOp(K, 2, @[A, B, C])).ok
  var short = act
  short.accountCount = 3
  short.accounts = @[]
  let bad = c.submit(A, proposeOp(K, 1, short))
  doAssert not bad.ok and "target_account_ids length (0) must equal target_account_count (3)" in bad.error, bad.error
  doAssert c.submit(A, proposeOp(K, 1, act)).ok
  doAssert c.readProposal(K, 1).proposal.action.accounts == act.accounts, "the ids are on chain"
  doAssert c.submit(B, approveOp(K, 1)).ok
  let swapped = c.submit(B, executeOp(K, 1, @[act.accounts[0], id32("thief")]))
  doAssert not swapped.ok and "Target account 1 does not match the approved proposal" in swapped.error, swapped.error
  doAssert c.submit(B, executeOp(K, 1, act.accounts)).ok
  doAssert c.chainedCalls[^1].accounts == act.accounts
  # the published program's count-only layout lets the substitution through (#40)
  let old = newFakeLezMultisig(Chain, psLee02, program, feePerTx = 0)
  doAssert old.submit(A, createOp(K, 2, @[A, B, C])).ok and old.submit(A, proposeOp(K, 1, act)).ok
  doAssert old.submit(B, approveOp(K, 1)).ok
  doAssert old.submit(B, executeOp(K, 1, @[act.accounts[0], id32("thief")])).ok
  doAssert old.chainedCalls[^1].accounts[1] == id32("thief"), "#40, as the published program behaves"
  echo "2. account-ids: the ids must match the count, a substituted account is refused; count-only still lets it through OK"

# ── 3. the driver ──────────────────────────────────────────────────────────────
proc cfgOf(layout: string): string =
  $(%*{"program": toHex(program), "createKey": toHex(K), "pda": "lee-v0.2", "layout": layout})
proc driverOf(layout: string): LezMultisigDriver =
  let (ok, a, detail) = lezMultisigAccountFromParts(Chain, toHex(statePda(psLee02, program, K)), cfgOf(layout),
                                                    @[toHex(A), toHex(B), toHex(C)], 2)
  doAssert ok, detail
  newLezMultisigDriver(a)
block:
  let d = driverOf("account-ids")
  doAssert d.account.layout == plAccountIds
  let e = effectFromJson(lezProposalEffect(1, act))
  doAssert d.checkRead(e, "proposal", encodeProposal(newProposal(1, A, K, act), plAccountIds)) == ""
  var other = act
  other.accounts = @[act.accounts[0], id32("elsewhere")]
  doAssert "target accounts" in d.checkRead(e, "proposal", encodeProposal(newProposal(1, A, K, other), plAccountIds))
  let p = d.profile()
  doAssert p.bypassesKnown and p.bypasses.len == 0, "with the accounts committed, nothing gets around the rule"
  doAssert cardRows(p).filterIt(it.key == "where")[0].credibility == "imperative"
  let old = driverOf("count-only")
  doAssert old.account.layout == plCountOnly and old.profile().bypasses.len == 1 and "#40" in old.profile().bypasses[0]
  let dflt = newLezMultisigDriver(lezMultisigAccountFromParts(Chain, toHex(statePda(psLee02, program, K)),
    $(%*{"program": toHex(program), "createKey": toHex(K), "pda": "lee-v0.2"}), @[toHex(A), toHex(B), toHex(C)], 2).account)
  doAssert dflt.account.layout == plCountOnly, "a config that names no layout is the published program"
  echo "3. the driver: account-ids checks the accounts on the re-read, no bypass on the card; count-only keeps #40 OK"

# ── 4. in the room ─────────────────────────────────────────────────────────────
block:
  let c = newFakeLezMultisig(Chain, psLee02, program, feePerTx = 1, layout = plAccountIds)
  c.fund(pay, 20)
  doAssert c.submit(A, createOp(K, 2, @[A, B, C]), payer = pay).ok
  var r = newRoom("/muster/1/lez-rebuilt/proto")
  r.alice.publish(accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: Chain,
    address: toHex(statePda(psLee02, program, K)), label: "T", signers: @[A, B, C].mapIt(toHex(it)),
    threshold: 2, config: cfgOf("account-ids")), "alice"))
  r.bob.poll()
  proc res(s: CoordinationSession): DriverFor =
    let sess = s
    result = proc(policy: string): Driver =
      driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
  let policy = qualify("lez-multisig", reduceAccounts(r.alice.log.allEvents())[0].id)
  let id = liveProposeOnChain(r.alice, aliceKs, res(r.alice), policy, act, newLezVoteSeam(c, A, pay), int64(Now), 1,
                              ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, res(r.bob), id, newLezVoteSeam(c, B, pay), bindCtx(), Now) == "executable"
  # a pointer whose on-chain accounts differ from what the room is told: refused before any vote
  var decoy = act
  decoy.accounts = @[act.accounts[0], id32("elsewhere")]
  doAssert c.submit(C, proposeOp(K, 2, decoy), payer = pay).ok
  let lying = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, lezProposalEffect(2, act), int64(Now), 2,
                                account = toHex(statePda(psLee02, program, K)), ttlSec = Ttl)
  r.bob.poll()
  let refused = liveVote(r.bob, bobKs, res(r.bob), lying, newLezVoteSeam(c, B, pay), bindCtx(), Now)
  doAssert refused.startsWith("refused") and "target accounts" in refused, refused
  let drv = res(r.alice)(policy)
  let stl = settlementFor(drv, c, Account(chain: Chain, form: afPublic, id: toHex(A) & ":" & toHex(pay)))
  let asm0 = stl.assemble(drv, effectFromJson(lezProposalEffect(1, act)), @[])
  doAssert asm0.ok, asm0.error & " " & asm0.detail
  doAssert stl.watch(stl.submit(asm0.tx, aliceKs)).status == fsFinal
  doAssert c.chainedCalls[^1].accounts == act.accounts, "Executed with exactly the reviewed accounts"
  echo "4. in the room: proposed, voted, settled with the reviewed accounts; a pointer to other accounts refused OK"

# ── 5. the real chain ──────────────────────────────────────────────────────────
block:
  let v = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-multisig-v024" / "chain.json"))
  let image = hexToBytes(v["program_image_id"].getStr())
  let tokenImage = hexToBytes(v["token_image_id"].getStr())
  proc acct(k: string): (seq[byte], seq[byte], seq[byte]) =
    let a = v["accounts"][k]
    (hexToBytes(a["id"].getStr()), hexToBytes(a["program_owner"].getStr()), hexToBytes(a["data"].getStr()))
  let (stateId, stateOwner, stateData) = acct("state")
  let st = decodeState(stateData)
  doAssert stateOwner == image, "the state account belongs to the program"
  doAssert encodeState(st) == stateData, "state: byte-exact round trip"
  doAssert st.threshold == 2 and st.members.len == 3 and st.transactionIndex == 2
  doAssert statePda(psLee02, image, st.createKey) == stateId, "the state PDA: /LEE/v0.2/ over the image id"
  let (vaultId, vaultOwner, _) = acct("vault")
  doAssert vaultPda(psLee02, image, st.createKey) == vaultId
  doAssert vaultOwner == tokenImage, "the vault holds tokens"
  for (k, idx) in [("proposal1", 1'u64), ("proposal2", 2'u64)]:
    let (pid, owner, data) = acct(k)
    let p = decodeProposal(data, plAccountIds)
    doAssert owner == image and p.index == idx and p.createKey == st.createKey
    doAssert encodeProposal(p, plAccountIds) == data, k & ": byte-exact round trip"
    doAssert proposalPda(psLee02, image, st.createKey, idx) == pid, k & ": the proposal PDA"
    doAssert p.status == psExecuted and p.approved.len == 2
    doAssert p.action.accounts.len == p.action.accountCount and p.action.pdaSeeds == @[vaultSeed(st.createKey)]
  # proposal 2 is the transfer: out of the vault, with the vault the authorized PDA
  let p2 = decodeProposal(acct("proposal2")[2], plAccountIds)
  doAssert p2.action.accounts[0] == vaultId and p2.action.authorized == @[0'u8]
  doAssert p2.action.target == tokenImage
  echo "5. the real chain (LEZ v0.2.4): state + proposals decode and re-encode byte for byte; PDAs derive OK"

echo "lez_multisig_rebuilt_test: the rebuilt program commits its target accounts; muster reads and checks them — all OK"
