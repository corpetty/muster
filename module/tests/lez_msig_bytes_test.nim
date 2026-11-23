## lez-msig's bytes in Nim, held to the program's own vectors (epic exo-0d3;
## tests/vectors/lez-msig, from programs/lez-msig/host/src/bin/msig_vectors.rs):
##   1. every borsh encoding — the config, a proposal of each action kind, a spend, the state,
##      and every instruction envelope a public multisig sends;
##   2. every tagged hash — the state seed, proposal ids, approve / execute / spend messages —
##      and the public PDA;
##   3. a BIP-340 signature made here, with the vector's aux, equals the program host's, and
##      the host's verify here;
##   4. the state decodes and re-encodes to the same bytes; a padded or short one is refused.
## Needs the secp closure.

import std/[json, options, os, strutils]
import stint
import ../src/lez/msig
import ../src/bitcoin/keys as btckeys
import ../src/bitcoin/tx                # hexToBytes

let v = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-msig" / "vectors.json"))["vectors"]
proc hb(k: string): seq[byte] = hexToBytes(v[k].getStr())
proc fill(x: byte): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 32: result[i] = x
var fails = 0
template check(cond: bool, what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc fails
proc same(got: seq[byte], key, what: string) =
  check(got == hb(key), what & (if got == hb(key): "" else: "\n       got  " & hexOf(got) & "\n       want " & v[key].getStr()))

let secrets = @[fill(1), fill(2), fill(3)]
let k1 = btckeys.xonlyPubKey(secrets[0])
let k2 = btckeys.xonlyPubKey(secrets[1])
let k3 = btckeys.xonlyPubKey(secrets[2])
let program = fill(0x11)
let createKey = fill(0x22)
let zone = fill(0x2e)
let aux = hb("aux")

echo "1. keys, seed, account"
same(k1, "key1", "member key 1"); same(k2, "key2", "member key 2"); same(k3, "key3", "member key 3")
same(stateSeed(createKey), "state_seed", "the state seed")
let a = multisigPublic(program, createKey)
same(a, "multisig_public", "the multisig's public PDA")

let config = MsigConfig(
  members: @[MsigMember(key: k1, roles: RoleAll, weight: 1),
             MsigMember(key: k2, roles: RolePropose or RoleApprove, weight: 2),
             MsigMember(key: k3, roles: RoleExecute, weight: 1)],
  threshold: 2, timelockMs: 3_600_000, openExecution: false, actions: ActAll,
  targets: @[fill(0x55)],
  limits: @[MsigLimit(id: 7, signers: @[k1, k2], threshold: 1, amount: 1_000_000.u128, periodMs: 86_400_000)])
same(borsh(config), "config", "the config")
same(envelopePublic(createKey, MsigInstruction(kind: ikCreate, zone: zone, config: config)), "create_envelope", "Create's envelope")
check(decodeMsigConfig(hb("config")) == config, "the config decodes to what encoded it")

echo "2. proposals of each action kind"
let k4 = btckeys.xonlyPubKey(fill(4))
let actions = @[
  ("transfer", MsigAction(kind: akTransfer, to: fill(0x0e), amount: 400.u128)),
  ("call", MsigAction(kind: akCall, program: fill(0x55),
                      rows: @[MsigRow(account: a, program: fill(0x55)), MsigRow(account: fill(0x0e), program: fill(0x55))],
                      data: @[1'u8, 2, 3])),
  ("config", MsigAction(kind: akConfig, changes: @[
    MsigChange(kind: ccAddMember, member: MsigMember(key: k4, roles: RoleApprove, weight: 1)),
    MsigChange(kind: ccRemoveMember, removed: k3),
    MsigChange(kind: ccSetRoles, rolesKey: k1, roles: RolePropose),
    MsigChange(kind: ccSetWeight, weightKey: k2, weight: 3),
    MsigChange(kind: ccSetThreshold, threshold: 3),
    MsigChange(kind: ccSetTimelock, timelockMs: 0),
    MsigChange(kind: ccSetOpenExecution, open: true),
    MsigChange(kind: ccSetActions, actions: ActTransfer),
    MsigChange(kind: ccSetTargets, targets: @[]),
    MsigChange(kind: ccAddLimit, limit: MsigLimit(id: 8, signers: @[k2], threshold: 1, amount: 5.u128, periodMs: 60_000)),
    MsigChange(kind: ccRemoveLimit, limitId: 7)])),
  ("cancel", MsigAction(kind: akCancel, nonces: @[3'u64, 300]))]
for (name, action) in actions:
  let p = MsigProposal(multisig: a, zone: zone, epoch: 5, nonce: 9, action: action,
                       expiresMs: 1_800_000_000_000'u64, proposer: k1)
  let id = proposalId(p)
  same(borsh(p), name & ".proposal", name & ": the proposal")
  same(id, name & ".proposal_id", name & ": its id")
  check(borsh(decodeProposal(hb(name & ".proposal"))) == hb(name & ".proposal"), name & ": the proposal decodes and re-encodes exactly")
  var refusedP = 0
  for badP in [hb(name & ".proposal") & @[0'u8], hb(name & ".proposal")[0 ..< ^1]]:
    try: discard decodeProposal(badP)
    except MsigDecodeError: inc refusedP
  check(refusedP == 2, name & ": a padded or short proposal is refused")
  same(approveMsg(id), name & ".approve_msg", name & ": what an approver signs")
  same(executeMsg(id), name & ".execute_msg", name & ": what an executor signs")
  let ap1 = btckeys.schnorrSign(secrets[0], approveMsg(id), aux)
  let ap2 = btckeys.schnorrSign(secrets[1], approveMsg(id), aux)
  let ex = btckeys.schnorrSign(secrets[2], executeMsg(id), aux)
  same(ap1, name & ".approve_sig1", name & ": member 1's approval, signed here")
  same(ex, name & ".execute_sig3", name & ": member 3's execution, signed here")
  check(verifySig(k1, approveMsg(id), hb(name & ".approve_sig1")), name & ": the host's approval verifies here")
  check(not verifySig(k2, approveMsg(id), hb(name & ".approve_sig1")), name & ": and not as another member's")
  check(not verifySig(k1, executeMsg(id), hb(name & ".approve_sig1")), name & ": nor as an execution")
  let approvals = @[MsigSigned(key: k1, sig: ap1), MsigSigned(key: k2, sig: ap2)]
  let exs = some(MsigSigned(key: k3, sig: ex))
  same(envelopePublic(createKey, MsigInstruction(kind: ikExecute, proposal: p, approvals: approvals, executor: exs)),
       name & ".execute_envelope", name & ": Execute's envelope")
  same(envelopePublic(createKey, MsigInstruction(kind: ikQueue, proposal: p, approvals: approvals, executor: exs,
                                                 atMs: 1_700_000_000_000'u64)),
       name & ".queue_envelope", name & ": Queue's envelope")
  same(envelopePublic(createKey, MsigInstruction(kind: ikExecuteQueued, proposal: p, executor: exs,
                                                 atMs: 1_700_003_600_000'u64)),
       name & ".execute_queued_envelope", name & ": ExecuteQueued's envelope")

echo "3. a spend under a limit"
let sp = MsigSpend(multisig: a, zone: zone, epoch: 5, limit: 7, nonce: 10, to: fill(0x0e), amount: 999.u128,
                   expiresMs: 1_800_000_000_000'u64)
same(borsh(sp), "spend", "the spend")
same(spendMsg(sp), "spend_msg", "what a limit's signer signs")
doAssert decodeSpend(borsh(sp)) == sp, "a spend decodes back to itself"
for bad in [borsh(sp)[0 ..< ^1], borsh(sp) & @[0'u8]]:
  try:
    discard decodeSpend(bad)
    doAssert false, "only exact bytes decode"
  except MsigDecodeError: discard
let spSig = btckeys.schnorrSign(secrets[0], spendMsg(sp), aux)
same(spSig, "spend_sig1", "member 1's spend signature, signed here")
same(envelopePublic(createKey, MsigInstruction(kind: ikSpend, spend: sp, spendApprovals: @[MsigSigned(key: k1, sig: spSig)],
                                               period: 19_675, periodMs: 86_400_000)),
     "spend_envelope", "Spend's envelope")

echo "4. the state"
let st = decodeMsigState(hb("state"))
check(st.epoch == 5 and st.nonceBase == 9 and st.config == config and st.queue.len == 1 and
      st.queue[0].nonce == 12 and st.usage[0].used == 999.u128, "the state decodes")
same(encodeMsigState(st), "state", "and re-encodes to the same bytes")
check(not st.nonceFree(9) == false and st.nonceFree(9), "nonce 9 (the base) is free")
check(not st.nonceFree(10) and not st.nonceFree(11) and st.nonceFree(12), "nonces 10 and 11 are spent, 12 is free")
check(st.nextNonce() == 9 and st.nextNonce(@[9'u64]) == 12, "the next nonce skips spent and taken ones")
check(approvalWeight(config, @[k1, k2, k2, k3]) == 3, "the APPROVE weight counts each member once, EXECUTE-only none")
var refused = 0
for bad in [hb("state") & @[0'u8], hb("state")[0 ..< ^1]]:
  try: discard decodeMsigState(bad)
  except MsigDecodeError: inc refused
check(refused == 2, "a padded or short state is refused")

echo "5. a private note"
let note = decodeNote(hb("note"))
check(note.nonce == 0x0102_0304.u128, "the note's nonce")
check(noteBalance(note) == 3800.u128, "the vault: the native shard")
check(noteState(note, program).isSome and encodeMsigState(noteState(note, program).get) == hb("state"),
      "the state: the program's own shard")
check(noteState(note, fill(0x99)).isNone, "another program's shard is not the multisig's")
var refusedN = 0
for badN in [hb("note") & @[0'u8], hb("note")[0 ..< ^1]]:
  try: discard decodeNote(badN)
  except MsigDecodeError: inc refusedN
check(refusedN == 2, "a padded or short note is refused")

if fails > 0:
  echo fails, " FAILED"
  quit 1
echo "lez_msig_bytes_test: all passed"
