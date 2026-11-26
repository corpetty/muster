## A lez-msig step's gas limit on LEZ v0.4 (exo-50c; src/lez/msig_gas.nim), held to what each step
## metered on LEE's own state (tests/vectors/lez-msig/v04-gas.json, from
## programs/lez-msig/lez04/host/tests/v04_gas.rs):
##   1. for every measured step (Create; Execute of a transfer or a config change; Queue;
##      ExecuteQueued; Spend; across member and approval counts) the declared limit covers what it
##      metered, and is not more than half again and 60k above it (a refusal burns the limit);
##   2. an envelope decodes back to the instruction it was built from, of every kind; a padded or
##      private envelope is refused;
##   3. the fee cap covers the reserve at the next block's highest base fee.

import std/[json, options, os]
import stint
import ../src/lez/[msig, msig_gas]

var fails = 0
template check(cond: bool, what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc fails

proc key(x: int): Key32 =
  result = newSeq[byte](32)
  result[0] = byte(x and 0xff); result[1] = byte(x shr 8); result[31] = 0x5a

proc config(n: int): MsigConfig =
  for i in 0 ..< n: result.members.add MsigMember(key: key(i), roles: RoleAll, weight: 1)
  result.threshold = 1; result.actions = ActAll; result.openExecution = true

proc signed(m: int): seq[MsigSigned] =
  for i in 0 ..< m: result.add MsigSigned(key: key(i), sig: newSeq[byte](64))

proc proposal(action: MsigAction): MsigProposal =
  MsigProposal(multisig: key(900), zone: key(901), epoch: 0, nonce: 0, action: action,
               expiresMs: 1_000_000, proposer: key(0))

let transfer = MsigAction(kind: akTransfer, to: key(902), amount: 10.u128)
let config2 = MsigAction(kind: akConfig, changes: @[MsigChange(kind: ccSetTimelock, timelockMs: 0),
                                                    MsigChange(kind: ccSetThreshold, threshold: 2)])

proc instruction(step: string, n, m: int): MsigInstruction =
  case step
  of "create": MsigInstruction(kind: ikCreate, zone: key(901), config: config(n))
  of "execute-transfer": MsigInstruction(kind: ikExecute, proposal: proposal(transfer), approvals: signed(m))
  of "execute-config": MsigInstruction(kind: ikExecute, proposal: proposal(config2), approvals: signed(m))
  of "queue": MsigInstruction(kind: ikQueue, proposal: proposal(transfer), approvals: signed(m), atMs: 500)
  of "execute-queued": MsigInstruction(kind: ikExecuteQueued, proposal: proposal(transfer), atMs: 1_500)
  of "spend":
    MsigInstruction(kind: ikSpend, spend: MsigSpend(multisig: key(900), zone: key(901), epoch: 1, limit: 1,
                    nonce: 1, to: key(902), amount: 30.u128, expiresMs: 1_000_000),
                    spendApprovals: signed(m), period: 0, periodMs: 10_000)
  else: raise newException(ValueError, "unknown step " & step)

echo "1. every measured step's limit covers it, without waste"
let rows = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-msig" / "v04-gas.json"))["rows"]
check(rows.len >= 60, "the table has every step (" & $rows.len & " rows)")
var worst = 0.0
for r in rows:
  let (step, n, m, cycles) = (r["step"].getStr(), r["n"].getInt(), r["m"].getInt(), uint64(r["cycles"].getInt()))
  let gas = gasLimitFor(instruction(step, n, m), n)
  let what = step & " n=" & $n & " m=" & $m & ": limit " & $gas & " for " & $cycles
  if gas < cycles: check(false, what & " (short)")
  elif gas > cycles + cycles div 2 + 60_000: check(false, what & " (wasteful)")
  worst = max(worst, float(gas) / float(cycles))
check(fails == 0, "every limit within [metered, 1.5 × metered + 60k]; worst ratio " & $worst)
check(gasLimitFor(MsigInstruction(kind: ikExecute, proposal: proposal(MsigAction(kind: akCall, program: key(7))),
                                  approvals: signed(2)), 3) >= CallAllowance, "a call carries its target's allowance")
check(gasLimitFor(instruction("execute-transfer", 100, 100), 100) == MaxGasExec, "capped at the zone's maximum")

echo "2. an envelope decodes back"
for (step, n, m) in [("create", 3, 0), ("execute-transfer", 3, 2), ("execute-config", 5, 3), ("queue", 3, 2),
                     ("execute-queued", 3, 0), ("spend", 3, 1)]:
  var op = instruction(step, n, m)
  if op.kind in {ikExecute, ikQueue, ikExecuteQueued}: op.executor = some MsigSigned(key: key(77), sig: newSeq[byte](64))
  let env = envelopePublic(key(55), op)
  let (ck, back) = decodePublicEnvelope(env)
  check(ck == key(55) and borsh(back) == borsh(op), step & " round-trips")
  check(gasLimitFor(back, n) == gasLimitFor(op, n), step & ": the same limit from the decoded envelope")
let env = envelopePublic(key(55), instruction("execute-transfer", 3, 2))
var raised = false
try: discard decodePublicEnvelope(env & @[0'u8]) except MsigDecodeError: raised = true
check(raised, "a padded envelope is refused")
raised = false
var priv = env
priv[32] = 1
try: discard decodePublicEnvelope(priv) except MsigDecodeError: raised = true
check(raised, "a private envelope is refused")

echo "3. the fee cap"
let gas = gasLimitFor(instruction("execute-transfer", 3, 2), 3)
check(maxFeeFor(gas, 830, 9) >= (gas + 830) * 9, "covers the reserve at the next block's ceiling")
check(maxFeeFor(gas, 830, 9) < 134_400_000'u64, "far below the v0.3 wallet default's cap")

echo "4. a private multisig's fee account against the next reserve (exo-8ef)"
# fee_core's private_fee_required(0, 8, 8) at v0.4.0-rc3: (409_764)·8 + (223_551 + 512)·8, the
# "about 5.07M at base fee 8" programs/lez-msig/BENCHMARKS.md measured on every private transaction
check(privateReserve(8, 8) == 5_070_616.u128, "the reserve at base fees 8/8 is LEZ's private fee: " & $privateReserve(8, 8))
check(privateReserve(10, 3) == (409_764 * 10 + 224_063 * 3).u128, "exec and storage priced apart")
check(privateReserve(8, 8, effectCycles = 1000) == 5_070_616.u128 + 8_000.u128, "effect cycles at the exec fee")
proc feeNote(balance: UInt128, other = false): seq[byte] =
  ## lee_core's Account, borsh: nonce u128, then {program: shard} (u32 count, each a key and a u32-sized vec)
  result = @(7.u128.toBytesLE())
  let shards = (if other: 2 else: 1)
  result.add @[byte(shards), 0, 0, 0]
  result.add newSeq[byte](32)                         # the native token program: all zero
  result.add @[16'u8, 0, 0, 0]
  result.add @(balance.toBytesLE())
  if other:
    result.add key(901)
    result.add @[3'u8, 0, 0, 0, 1, 2, 3]
let reserve = privateReserve(8, 8)
block:
  let s = feeAccountStatus(feeNote(50_000_000.u128), reserve)
  check(s.funded and s.balance == 50_000_000.u128 and not s.low and s.covers == 9.u128,
        "a topped-up account: its balance from the note, enough for 9 transactions")
block:
  let s = feeAccountStatus(feeNote(5_070_615.u128), reserve)
  check(s.low and s.covers == 0.u128, "one short of the reserve is low: the next proof would fail")
block:
  let s = feeAccountStatus(feeNote(reserve), reserve)
  check(not s.low and s.covers == 1.u128, "exactly the reserve pays the next transaction")
block:
  let s = feeAccountStatus(feeNote(6_000_000.u128, other = true), reserve)
  check(s.balance == 6_000_000.u128, "the balance is the native shard, whatever else the note holds")
block:
  let s = feeAccountStatus(newSeq[byte](), reserve)
  check(not s.funded and s.balance == 0.u128 and s.low, "no note yet: an empty account, low")
block:
  var raisedN = false
  try: discard feeAccountStatus(feeNote(1.u128) & @[0'u8], reserve)
  except MsigDecodeError: raisedN = true
  check(raisedN, "a note that does not decode raises, never reads as zero")

if fails > 0:
  echo fails, " failed"
  quit 1
echo "msig_gas_test: all passed"
