## What a lez-msig step declares as its gas limit and fee cap on LEZ v0.4 (exo-50c). On 0.4 a
## refused transaction burns its whole declared gas limit, so a limit sized for the worst case
## (the LEZ wallet's default, 2M) costs every refusal about 16M at base fee 8. Muster cannot
## simulate a step as LEZ's wallet does (that runs the program), so it declares a limit from a
## model of what each step meters, fitted to measurements on LEE's own state
## (programs/lez-msig/lez04/host/tests/v04_gas.rs → tests/vectors/lez-msig/v04-gas.json) and held
## above every one of them by msig_gas_test. What drives the cost:
## - each approval, or an executor's signature, is a BIP-340 verification in the guest: ~275k;
## - a config change re-checks the whole config: ~29k per member;
## - Create writes the config: ~30k per member;
## - ExecuteQueued carries no approvals: ~30k.
## A call's target runs inside the step and costs what it costs, so a call gets a fixed allowance.

import std/options
import stint
import ./msig

const
  PerSignature = 290_000'u64
  StepBase = 32_000'u64
  PerMember = 1_000'u64
  ConfigPerMember = 32_000'u64
  ConfigPerChange = 10_000'u64
  CreateBase = 20_000'u64
  CreatePerMember = 32_000'u64
  CallAllowance* = 2_000_000'u64
    ## a call's target is another program, unmeasured here; a refusal of it burns this much more
  Headroom = 25_000'u64
  MaxGasExec* = 10_000_000'u64
    ## the zone's per-transaction cap (getFeeState max_gas_exec at 0.4.0-rc3)

proc actionCost(a: MsigAction, members: int): uint64 =
  case a.kind
  of akTransfer, akCancel: 0'u64
  of akConfig: ConfigPerMember * uint64(members) + ConfigPerChange * uint64(a.changes.len)
  of akCall: CallAllowance

proc gasLimitFor*(op: MsigInstruction, members: int): uint64 =
  ## The gas limit a step declares: the model plus an eighth and a fixed headroom, capped at the
  ## zone's maximum. `members` is the multisig's member count as the chain holds it (a Create
  ## counts its own config's).
  let sigs = proc (xs: seq[MsigSigned], executor: Option[MsigSigned]): uint64 =
    PerSignature * uint64(xs.len + (if executor.isSome: 1 else: 0))
  let model =
    case op.kind
    of ikCreate:
      CreateBase + CreatePerMember * uint64(op.config.members.len)
    of ikExecute, ikQueue:
      StepBase + PerMember * uint64(members) + sigs(op.approvals, op.executor) +
        actionCost(op.proposal.action, members)
    of ikExecuteQueued:
      StepBase + PerMember * uint64(members) + sigs(@[], op.executor) +
        actionCost(op.proposal.action, members)
    of ikSpend:
      StepBase + PerMember * uint64(members) + sigs(op.spendApprovals, none MsigSigned)
  min(model + model div 8 + Headroom, MaxGasExec)

proc maxFeeFor*(gasLimit: uint64, wireBytes: int, baseFeeCeiling: uint64): uint64 =
  ## The fee cap: the reserve at twice the next block's highest possible base fee, so a step
  ## that waits a few blocks in the mempool is not refused for a rising fee. Unused fee is
  ## refunded; the cap is what the payer must cover.
  (gasLimit + uint64(wireBytes)) * baseFeeCeiling * 2

# ── a private multisig's fee account (LEZ v0.4, D17, exo-8ef) ──────────────────────────────
# Every private transaction pays its fee inside its proof, from the group's fee account. The
# executor (programs/lez-msig/lez04/host/src/exec.rs `reserve`) prices it as LEZ's private fee at
# the next block's highest base fees (`private_reserve`: fee_core's `private_fee_required` with no
# public cycles), and the whole reserve leaves the account: its surplus over the fee is kept as tip.

const
  PrivateVerifyGas* = 409_764'u64
    ## fee_core::market::PRIVATE_VERIFY_GAS at v0.4.0-rc3: the execution gas every private
    ## transaction is charged, for verifying its succinct receipt
  PrivateGasStor* = 223_551'u64 + 512'u64
    ## fee_core::market::PRIVATE_GAS_STOR at v0.4.0-rc3 (PROOF_BYTES + PRIVATE_PAD_BYTES): the
    ## size every private transaction is priced at

proc privateReserve*(nextExecCeiling, nextStorCeiling: uint64, effectCycles = 0'u64): UInt128 =
  ## What the next private transaction takes from the fee account:
  ## `(PRIVATE_VERIFY_GAS + effect cycles)·exec + PRIVATE_GAS_STOR·stor` at the next block's
  ## ceilings (getFeeState), as the executor prices it (it passes no effect cycles).
  (PrivateVerifyGas.u128 + effectCycles.u128) * nextExecCeiling.u128 + PrivateGasStor.u128 * nextStorCeiling.u128

type FeeAccountStatus* = object
  funded*: bool          ## the room carries a note of the fee account: someone topped it up
  balance*: UInt128      ## its native balance, from that note
  reserve*: UInt128      ## what the next private transaction takes
  low*: bool             ## the balance cannot pay the next private transaction: it would fail while proving
  covers*: UInt128       ## how many private transactions the balance pays for at this reserve

proc feeAccountStatus*(feeNote: openArray[byte], reserve: UInt128): FeeAccountStatus =
  ## The fee account as the newest note of it a member opened shows it, against the next
  ## transaction's reserve. No note yet reads as an empty account. A note that does not decode
  ## raises (MsigDecodeError): it is never read as a zero balance.
  result.reserve = reserve
  if feeNote.len > 0:
    result.funded = true
    result.balance = noteBalance(decodeNote(feeNote))
  result.low = result.balance < reserve
  result.covers = (if reserve == 0.u128: 0.u128 else: result.balance div reserve)
