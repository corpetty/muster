## The quest record program, in process (exo-267.8): the rules of programs/lez-quest's
## plan and apply (quest_program/src/lib.rs), with its messages, as a FakeProgram the fake
## LEZ zone runs (lez/multisig_chain.nim addProgram). An account is authorized when it is
## in the call's grants: the transaction's signer, or the vault a multisig's Execute grants.
## The bounty moves by the transfers this returns: from the issuer into the record at
## Open, from the record (the program's own PDA) at Close and Cancel. The real program is
## the arbiter; programs/lez-quest's tests and quest_e2e hold it.

import stint
import ./multisig
import ./multisig_chain
import ./quest

proc u64Of(x: UInt128): uint64 =
  if x > high(uint64).stuint(128): raise newException(LezDecodeError, "a bounty beyond the fake's u64 balances")
  x.truncate(uint64)

proc questFake*(program: seq[byte], scheme: PdaScheme): FakeProgram =
  let q = program
  result = proc (read: proc (id: seq[byte]): LezRead, grants: seq[seq[byte]], call: LezAction): FakeCallResult =
    template no(msg: string) = return FakeCallResult(refusal: msg)
    let zero = newSeq[byte](32)
    let rows = call.shards
    var ins: QuestInstruction
    try: ins = decodeQuestInstruction(call.data)
    except LezDecodeError as e: no("instruction must decode from borsh: " & e.msg)
    proc signer(i: int, what: string): tuple[ok: bool, who: seq[byte], why: string] =
      if rows[i].program != q: return (false, @[], "the " & what & " row names another program's shard")
      if rows[i].account notin grants: return (false, @[], "the " & what & " did not sign")
      (true, rows[i].account, "")
    proc theRecord(issuer: seq[byte]): string =
      if rows[0].account != questRecordPda(scheme, q, issuer, ins.questId): return "not this quest's record"
      if rows[0].program != q: return "the record row names another program's shard"
      ""
    proc bountyRows(src, dst: seq[byte]): bool =
      rows[2].account == src and rows[2].program == zero and rows[3].account == dst and rows[3].program == zero
    var bounty: uint64
    try: bounty = u64Of(ins.bounty)
    except LezDecodeError as e: no(e.msg)
    case ins.kind
    of qiOpen, qiClose, qiCancel:
      if rows.len != (if bounty > 0: 4 else: 2): no("the record, the signer, then the bounty's two native rows")
      let (sok, issuer, swhy) = signer(1, "issuer")
      if not sok: no(swhy)
      let rwhy = theRecord(issuer)
      if rwhy.len > 0: no(rwhy)
      let pre = read(rows[0].account)
      case ins.kind
      of qiOpen:
        if ins.taker.len > 0 and ins.taker == ins.confirmer: no("the taker cannot be the confirmer")
        if pre.data.len > 0: no("a quest already exists here")
        if bounty > 0 and not bountyRows(issuer, rows[0].account):
          no("the bounty's rows are the sender's and the recipient's native shards")
        result.writes.add (rows[0].account, encodeQuestRecord(QuestRecord(issuer: issuer, questId: ins.questId,
          termsHash: ins.termsHash, bounty: ins.bounty, confirmer: ins.confirmer, namedTaker: ins.taker, status: qsOpen)))
        if bounty > 0: result.transfers.add (issuer, rows[0].account, bounty)
      of qiClose:
        if pre.data.len == 0: no("no quest here")
        var r = decodeQuestRecord(pre.data)
        if bounty > 0 and not bountyRows(rows[0].account, ins.taker):
          no("the bounty's rows are the sender's and the recipient's native shards")
        if r.status != qsConfirmed: no("the quest is not confirmed")
        if issuer != r.issuer: no("not this quest's issuer")
        if ins.taker != r.statusTaker: no("not the taker who took it")
        if ins.bounty != r.bounty: no("not the bounty the quest holds")
        r.status = qsClosed
        result.writes.add (rows[0].account, encodeQuestRecord(r))
        if bounty > 0: result.transfers.add (rows[0].account, ins.taker, bounty)
      else:
        if pre.data.len == 0: no("no quest here")
        var r = decodeQuestRecord(pre.data)
        if bounty > 0 and not bountyRows(rows[0].account, issuer):
          no("the bounty's rows are the sender's and the recipient's native shards")
        if r.status notin {qsOpen, qsAccepted}: no("the quest cannot be cancelled once confirmed, closed or cancelled")
        if issuer != r.issuer: no("not this quest's issuer")
        if ins.bounty != r.bounty: no("not the bounty the quest holds")
        r.status = qsCancelled
        r.statusTaker = @[]
        result.writes.add (rows[0].account, encodeQuestRecord(r))
        if bounty > 0: result.transfers.add (rows[0].account, issuer, bounty)
    of qiAccept, qiConfirm:
      if rows.len != 2: no("two rows: the record, the signer")
      let rwhy = theRecord(ins.issuer)
      if rwhy.len > 0: no(rwhy)
      let what = (if ins.kind == qiAccept: "taker" else: "confirmer")
      let (sok, who, swhy) = signer(1, what)
      if not sok: no(swhy)
      let pre = read(rows[0].account)
      if pre.data.len == 0: no("no quest here")
      var r = decodeQuestRecord(pre.data)
      if ins.kind == qiAccept:
        if r.status != qsOpen: no("the quest is not open")
        if who == r.confirmer: no("the taker cannot be the confirmer")
        if r.namedTaker.len > 0 and who != r.namedTaker: no("not the taker this quest names")
        r.status = qsAccepted
        r.statusTaker = who
      else:
        if r.status != qsAccepted: no("the quest is not accepted")
        if who != r.confirmer: no("not this quest's confirmer")
        r.status = qsConfirmed
      result.writes.add (rows[0].account, encodeQuestRecord(r))
