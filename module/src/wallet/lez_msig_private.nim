## A private lez-msig's chain seam (exo-efa, docs/design/lez-msig.md §6). The multisig is a
## group-owned private PDA: its state is a note only its members read, and each transaction is
## a privacy-preserving one that LEZ's own prover makes (`MsigProver`, the lez_msig_module).
##
## `MsigPrivate` is the public seam with three differences, so the settlement's rules (the
## approvals, the epoch, the nonce, the time lock) are the same code for both postures:
##   * `readMsig` reads the latest note, which the room carries sealed (msig_room.latestNote);
##   * `sendOp` hands the program's instruction to the prover, which proves it over that note
##     and sends it; the answer is a job ("job:<id>"), because a proof takes minutes;
##   * `included` follows the job, then the transaction. Once the chain includes it, the new
##     note becomes the state and `onNote` hands it to the host, which seals it into the room.
## A deposit (`fund`) is a native transfer from this member's public LEZ account into the
## vault: the prover proves it, the keystore signs its hash, and the prover sends it. No key
## leaves the keystore, and the group secret goes only to the prover, for the job.
##
## On LEZ v0.4 (exo-05f) every transaction pays its fee inside its proof from the group's fee
## account (D17), whose note travels beside the multisig's: each request carries `feeNote`, each
## answer the new one (`feePost`), and `onFeeNote` hands it to the host to seal into the room.
## `topUp` funds the fee account from this member's public account, signed like a deposit. On
## v0.3 the prover answers no `feePost`, and none of this applies.

import std/[json, options, strutils, tables]
import stint
import ../lez/msig
import ../lez/tx as leztx     # LezShard
import ../crypto/keystore
import ./types
import ./lez_multisig_live        # LezRpc
import ./lez_msig_chain
import ./msig_prover

type
  PrivJob = object
    n: int                        ## the note this transaction makes
    feeN: int                     ## the fee account's note it makes (v0.4)
    fund: bool                    ## a deposit or a top-up: signed here, then sent by the prover
    topUp: bool                   ## a top-up makes no multisig note
    scan: bool                    ## a read of the newest note from the chain, sending nothing
    txHash, failed: string
    post, feePost: seq[byte]
    applied: bool

  MsigPrivate* = ref object of MsigLive
    prover*: MsigProver
    rpcUrl*: string
    gms*, createKey*: seq[byte]
    note*: seq[byte]              ## the latest note (lee_core Account, borsh); empty before Create
    noteN*: int                   ## its number; -1 before Create
    onNote*: proc(n: int, note: seq[byte], hash: string) {.closure.}
    feeNote*: seq[byte]           ## the group fee account's latest note (v0.4); empty before a top-up
    feeNoteN*: int                ## its number; -1 before the first top-up
    onFeeNote*: proc(n: int, note: seq[byte], hash: string) {.closure.}
    jobs: Table[string, PrivJob]

proc newMsigPrivate*(rpc: LezRpc, rpcUrl: string, ks: Keystore, chain: string, program: seq[byte],
                     payerLabel: string, prover: MsigProver, gms, createKey: seq[byte]): MsigPrivate =
  MsigPrivate(rpc: rpc, rpcUrl: rpcUrl, ks: ks, chain: chain, program: program, payerLabel: payerLabel,
              prover: prover, gms: gms, createKey: createKey, noteN: -1, feeNoteN: -1)

proc learn*(c: MsigPrivate, n: int, note: seq[byte]) =
  ## A note the room carries; the newest one is the state.
  if n > c.noteN and note.len > 0:
    c.note = note
    c.noteN = n

proc learnFee*(c: MsigPrivate, n: int, note: seq[byte]) =
  ## The fee account's note the room carries (v0.4); the newest one pays the next fee.
  if n > c.feeNoteN and note.len > 0:
    c.feeNote = note
    c.feeNoteN = n

proc unz(h: string): seq[byte] =
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc request(c: MsigPrivate, mode: string): JsonNode =
  %*{"mode": mode, "rpc": c.rpcUrl, "program": hexOf(c.program), "gms": hexOf(c.gms),
     "createKey": hexOf(c.createKey), "pre": (if c.note.len > 0: %hexOf(c.note) else: newJNull()),
     "feeNote": (if c.feeNote.len > 0: %hexOf(c.feeNote) else: newJNull())}

proc derive*(c: MsigPrivate): seq[byte] =
  ## The multisig's private PDA, which only a holder of the group secret can derive.
  let a = c.prover.derive(c.request("derive"))
  if a.hasKey("error"): raise newException(WalletError, "the prover could not derive it: " & a{"detail"}.getStr())
  unz(a["account"].getStr())

method readMsig*(c: MsigPrivate, account: seq[byte]): MsigRead =
  result.height = c.rpc.lastBlockId()
  if c.note.len == 0: return
  let n = decodeNote(c.note)
  let st = noteState(n, c.program)
  if st.isSome:
    result.found = true
    result.state = st.get
  result.balance = noteBalance(n)

proc submitted(c: MsigPrivate, a: JsonNode, fund: bool, topUp = false): MsigSent =
  if a.hasKey("error"): return MsigSent(ok: false, error: a{"error"}.getStr() & ": " & a{"detail"}.getStr())
  let id = "job:" & a{"job"}.getStr()
  c.jobs[id] = PrivJob(n: c.noteN + 1, feeN: c.feeNoteN + 1, fund: fund, topUp: topUp)
  MsigSent(ok: true, hash: id)

proc sendOp*(c: MsigPrivate, op: seq[byte]): MsigSent =
  ## The program's instruction (msig_core::Instruction, borsh), proved over the latest note.
  var r = c.request("exec")
  r["op"] = %hexOf(op)
  c.submitted(c.prover.submit(r), fund = false)

proc recover*(c: MsigPrivate, fromBlock = 1'u64): MsigSent =
  ## Read the newest note from the chain, for when the member whose transaction landed went
  ## away before sealing its note into the room (exo-abc): the prover decrypts every private
  ## action from `fromBlock` on with the group's viewing key. Followed like any job; once done
  ## its note becomes the state and `onNote` hands it to the room. Sends nothing.
  var r = c.request("scan")
  r["from"] = % $fromBlock
  let a = c.prover.submit(r)
  if a.hasKey("error"): return MsigSent(ok: false, error: a{"error"}.getStr() & ": " & a{"detail"}.getStr())
  let id = "job:" & a{"job"}.getStr()
  c.jobs[id] = PrivJob(n: c.noteN + 1, feeN: c.feeNoteN + 1, scan: true)
  MsigSent(ok: true, hash: id)

proc fund*(c: MsigPrivate, amount: UInt128): MsigSent =
  ## A deposit into the vault from this member's own public LEZ account.
  if c.note.len == 0: return MsigSent(ok: false, error: "the multisig is not created yet")
  var r = c.request("fund")
  try: r["payerNonce"] = % $c.rpc.getAccount(c.payer()).nonce
  except CatchableError as e: return MsigSent(ok: false, error: "could not read the payer's nonce: " & e.msg)
  r["payerKey"] = %hexOf(c.ks.lezMemberKey(c.payerLabel))
  r["amount"] = % $amount
  c.submitted(c.prover.submit(r), fund = true)

proc topUp*(c: MsigPrivate, amount: UInt128): MsigSent =
  ## A top-up of the group's fee account (v0.4, D17) from this member's own public LEZ account:
  ## proved by the prover, signed in the keystore, sent by the prover. The fee account pays this
  ## transaction's own fee out of `amount`, so a group with no funds can start.
  var r = c.request("topup")
  try: r["payerNonce"] = % $c.rpc.getAccount04(c.payer()).nonce
  except CatchableError as e: return MsigSent(ok: false, error: "could not read the payer's nonce: " & e.msg)
  r["payerKey"] = %hexOf(c.ks.lezMemberKey(c.payerLabel))
  r["amount"] = % $amount
  c.submitted(c.prover.submit(r), fund = true, topUp = true)

method sendMsig*(c: MsigPrivate, shards: seq[LezShard], instruction: seq[byte]): MsigSent =
  MsigSent(ok: false, error: "a private multisig sends through its prover (sendOp)")

proc failure*(c: MsigPrivate, hash: string): string =
  ## Why a job failed ("" while it has not): the program's refusal at proving time, or the
  ## sequencer's.
  c.jobs.getOrDefault(hash).failed

proc txHashOf*(c: MsigPrivate, hash: string): string = c.jobs.getOrDefault(hash).txHash

method included*(c: MsigPrivate, hash: string): bool =
  ## A job counts as included once its transaction is, or once it failed (the caller asks
  ## `failure`, and judges the rest by the state it reads, as for a public transaction).
  if not hash.startsWith("job:"): return procCall MsigLive(c).included(hash)
  if hash notin c.jobs: return false
  var j = c.jobs[hash]
  if j.failed.len > 0 or (j.scan and j.applied): return true
  if j.txHash.len == 0:
    let id = hash[4 .. ^1]
    let a = c.prover.job(id)
    case a{"state"}.getStr()
    of "proving": return false
    of "done":
      j.post = unz(a{"post"}.getStr())
      j.feePost = unz(a{"feePost"}.getStr())
      if j.scan:
        # nothing was sent: the note the chain holds, or none newer than the room's
        c.prover.forget(id)
        j.applied = true
        c.jobs[hash] = j
        if a{"found"}.getBool() and j.post.len > 0 and j.post != c.note:
          c.learn(max(j.n, c.noteN + 1), j.post)
          if c.onNote != nil: c.onNote(c.noteN, j.post, a{"hash"}.getStr())
        if a{"feeFound"}.getBool() and j.feePost.len > 0 and j.feePost != c.feeNote:
          c.learnFee(max(j.feeN, c.feeNoteN + 1), j.feePost)
          if c.onFeeNote != nil: c.onFeeNote(c.feeNoteN, j.feePost, a{"hash"}.getStr())
        return true
      if j.fund:
        var h: array[32, byte]
        let sign = unz(a{"sign"}.getStr())
        if sign.len != 32:
          j.failed = "the prover gave no message to sign"
        else:
          for i in 0 ..< 32: h[i] = sign[i]
          let sent = c.prover.send(%*{"rpc": c.rpcUrl, "message": a["message"], "proof": a["proof"],
            "witnesses": [{"signature": hexOf(c.ks.lezMemberSign(c.payerLabel, h)),
                           "publicKey": hexOf(c.ks.lezMemberKey(c.payerLabel))}]})
          if sent.hasKey("error"): j.failed = sent{"error"}.getStr() & ": " & sent{"detail"}.getStr()
          else: j.txHash = sent{"hash"}.getStr()
      else:
        j.txHash = a{"hash"}.getStr()
      c.prover.forget(id)
    else:
      j.failed = a{"error"}.getStr("failed") & ": " & a{"detail"}.getStr()
    c.jobs[hash] = j
    if j.failed.len > 0: return true
  var known = false
  try: known = c.rpc.getTransaction(j.txHash).known
  except CatchableError: return false
  if not known: return false
  if not j.applied:
    j.applied = true
    c.jobs[hash] = j
    if not j.topUp:
      c.learn(j.n, j.post)
      if c.onNote != nil: c.onNote(j.n, j.post, j.txHash)
    if j.feePost.len > 0:
      c.learnFee(j.feeN, j.feePost)
      if c.onFeeNote != nil: c.onFeeNote(j.feeN, j.feePost, j.txHash)
  true
