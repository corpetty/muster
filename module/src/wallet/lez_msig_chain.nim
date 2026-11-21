## The chain seam a lez-msig settlement needs (epic exo-0d3): read the multisig's state, send
## its instructions, and see whether the chain included them. It also gives the chain's time,
## for the time lock's windows.
##
## `MsigLive` is the user's own LEZ sequencer (invariant 8), through `LezRpc`. The instruction
## goes out as a public v0.3 transaction from this member's own funded LEZ account: the
## keystore signs under `payerLabel` (never exported), and that account pays the fee. The
## multisig's account signs nothing: its authority is its members' approvals, which the program
## checks. A transaction the program refuses is INCLUDED on v0.3 and pays, so a caller judges
## a step by the state it reads back, never by inclusion (docs/labbook/lez-v03-migration.md
## trap 8).

import std/[options, tables, times]
import stint
import ../lez/msig
import ../lez/msig_gas
import ../lez/tx as leztx
import ../lez/account_view
import ../crypto/keystore
import ./types
import ./adapter
import ./lez_multisig_live        # LezRpc

type
  MsigRead* = object
    found*: bool                  ## the account holds a multisig state
    state*: MsigState
    balance*: UInt128             ## the vault: the account's native balance
    height*: uint64

  MsigSent* = object
    ok*: bool
    hash*, error*: string

  MsigChain* = ref object of ChainAdapter
    chain*: string                ## CAIP-2
    program*: seq[byte]           ## the lez-msig program's account id

method readMsig*(c: MsigChain, account: seq[byte]): MsigRead {.base.} =
  raise newException(WalletError, "MsigChain.readMsig is abstract")
method sendMsig*(c: MsigChain, shards: seq[LezShard], instruction: seq[byte]): MsigSent {.base.} =
  raise newException(WalletError, "MsigChain.sendMsig is abstract")
method included*(c: MsigChain, hash: string): bool {.base.} =
  raise newException(WalletError, "MsigChain.included is abstract")
method nowMs*(c: MsigChain): uint64 {.base.} =
  ## The time the chain's windows are judged against. Block timestamps are the sequencer's
  ## wall clock (lez/sequencer/core: Utc::now), so this host's clock is the best estimate.
  uint64(epochTime() * 1000.0)

method describe*(c: MsigChain): ChainDescriptor =
  let native = AssetId(chain: c.chain, symbol: "LEZ", kind: akNative, decimals: 9)
  ChainDescriptor(chain: c.chain, displayName: "Logos Execution Zone (" & c.chain & ")",
                  nativeAsset: native, accountForms: @[afPublic], finality: finImmediate)

method finality*(c: MsigChain, txRef: TxRef): Finality =
  if c.included(txRef.id): Finality(status: fsFinal, detail: "included")
  else: Finality(status: fsPending, detail: "not included yet")

proc msigShards*(program, account: seq[byte], ins: MsigInstruction): seq[LezShard] =
  ## The transaction's rows: the multisig's own shard, then exactly what its outflow selects.
  ## This is the program's own plan check (methods/guest), in the same order.
  result = @[LezShard(account: account, program: program)]
  proc pay(to: seq[byte]): seq[LezShard] = @[nativeShard(account), nativeShard(to)]
  case ins.kind
  of ikCreate, ikQueue: discard
  of ikSpend: result.add pay(ins.spend.to)
  of ikExecute, ikExecuteQueued:
    let a = ins.proposal.action
    case a.kind
    of akTransfer: result.add pay(a.to)
    of akCall:
      for r in a.rows: result.add LezShard(account: r.account, program: r.program)
    of akConfig, akCancel: discard

proc msigActors*(program, account: seq[byte], ins: MsigInstruction): seq[LezActor] =
  ## LEZ v0.4 (roadmap M3): the public actors a transaction declares, as the program's v0.4 host
  ## builds them (lez04 `Msig::public_actors`): the multisig's own actor, then what the outflow
  ## touches. A call's rows are each an actor, its target first.
  result = @[LezActor(account: account, program: program)]
  case ins.kind
  of ikCreate, ikQueue: discard
  of ikSpend: result.add @[nativeActor(account), nativeActor(ins.spend.to)]
  of ikExecute, ikExecuteQueued:
    let a = ins.proposal.action
    case a.kind
    of akTransfer: result.add @[nativeActor(account), nativeActor(a.to)]
    of akCall:
      for r in a.rows: result.add LezActor(account: r.account, program: r.program)
    of akConfig, akCancel: discard

proc msigAdmission*(program, createKey: seq[byte], ins: MsigInstruction): seq[LezEvidence] =
  ## v0.4: a Create on a public PDA no one has used yet is admitted by evidence that it is the PDA
  ## of (program, seed); nothing else needs any.
  if ins.kind == ikCreate:
    result = @[LezEvidence(kind: ekPda, pdaProgram: program, seed: stateSeed(createKey))]

# ── live: the user's own sequencer ────────────────────────────────────────────
type MsigLive* = ref object of MsigChain
  rpc*: LezRpc
  ks*: Keystore
  payerLabel*: string             ## the keystore label of the member account that sends and pays
  sent: Table[string, float]
  line*: string                   ## "v0.3" or "v0.4": how this zone wants transactions; "" until read

proc newMsigLive*(rpc: LezRpc, ks: Keystore, chain: string, program: seq[byte], payerLabel: string): MsigLive =
  MsigLive(rpc: rpc, ks: ks, chain: chain, program: program, payerLabel: payerLabel)

proc payer*(c: MsigLive): seq[byte] = publicAccountId(c.ks.lezMemberKey(c.payerLabel))

proc zoneLine*(c: MsigLive): string =
  ## The zone's line, from how it answers for the program's own account (deployed, so never
  ## fresh): v0.4 answers in actor states, v0.3 in shards. Read once.
  if c.line.len == 0:
    let a = c.rpc.getAccount(c.program)
    c.line = (if a.v4: "v0.4" else: "v0.3")
  c.line

proc account*(c: MsigLive, id: seq[byte]): LezAccountState =
  ## An account read for this zone's line: on v0.4 an account no one has used reads as fresh.
  if c.zoneLine() == "v0.4": c.rpc.getAccount04(id) else: c.rpc.getAccount(id)

method readMsig*(c: MsigLive, account: seq[byte]): MsigRead =
  let h = c.rpc.lastBlockId()
  let a = c.account(account)
  result = MsigRead(height: h, balance: a.balance)
  for (prog, data) in a.shards:
    if prog == c.program and data.len > 0:
      result.found = true
      result.state = decodeMsigState(data)

method sendMsig*(c: MsigLive, shards: seq[LezShard], instruction: seq[byte]): MsigSent =
  ## One public transaction to the program, from this member's funded account, which pays its
  ## fee. On v0.4 (roadmap M3) the rows become the transaction's public actors (the same
  ## (account, program) pairs, the multisig's own first), and a public multisig no one has used
  ## yet is admitted by evidence that it is the PDA of (program, the create key's seed): the
  ## create key is the envelope's first 32 bytes and a public placement its 33rd (v04/src/lib.rs).
  ## A payee no one has used yet is left undeclared, so its credit waits for it as a pending
  ## message rather than refusing the transaction.
  let payer = c.payer()
  var hashOf: array[32, byte]
  var txBytes: seq[byte]
  var want: string
  try:
    let nonce = c.account(payer).nonce
    if c.zoneLine() == "v0.4":
      # a refused v0.4 transaction burns its whole gas limit, so the limit is this step's own
      # (lez/msig_gas.nim, exo-50c), never the wallet's 2M default
      let (_, op) = decodePublicEnvelope(instruction)
      let members = (if op.kind == ikCreate: op.config.members.len
                     else: c.readMsig(shards[0].account).state.config.members.len)
      let gas = gasLimitFor(op, members)
      var m = LezMessage4(root: LezActor(account: shards[0].account, program: shards[0].program),
                          message: instruction, nonces: @[(account: payer, nonce: nonce)],
                          fee: some LezFee(payer: payer, gasLimit: gas, tip: 0, maxFee: 0.u128))
      for i, s in shards:
        # a payee no one has used yet is not declared: v0.4 refuses a declared public account it
        # cannot admit (only the payee's key would), and an undeclared credit waits as a pending
        # message the payee claims (roadmap M3; LEZ's wallet does the same)
        if i > 0 and s.program == NativeTokenProgram and s.account != shards[0].account and
           c.account(s.account).fresh(): continue
        m.actors.add LezActor(account: s.account, program: s.program)
      if instruction.len > 32 and instruction[32] == 0 and c.account(shards[0].account).fresh():
        m.evidence = @[LezEvidence(kind: ekPda, pdaProgram: c.program, seed: stateSeed(instruction[0 ..< 32]))]
      # the cap covers the reserve over the wire bytes too; the fee fields are fixed-size, so
      # the length with a zero cap is the length with the real one
      let wire = leeTxPublic(m, @[LezWitness(signature: newSeq[byte](64), xonly: newSeq[byte](32))]).len
      m.fee.get.maxFee = maxFeeFor(gas, wire, c.rpc.feeCeiling()).stuint(128)
      hashOf = messageHash(m)
      let ws = @[LezWitness(signature: c.ks.lezMemberSign(c.payerLabel, hashOf), xonly: c.ks.lezMemberKey(c.payerLabel))]
      want = publicTxHash(m, ws)
      txBytes = leeTxPublic(m, ws)
    else:
      let m = LezMessage3(programAccount: c.program, shards: shards, nonces: @[nonce],
                          instruction: instruction, fee: some defaultFee(payer))
      hashOf = messageHash(m)
      let ws = @[LezWitness(signature: c.ks.lezMemberSign(c.payerLabel, hashOf), xonly: c.ks.lezMemberKey(c.payerLabel))]
      want = publicTxHash(m, ws)
      txBytes = leeTxPublic(m, ws)
  except MsigDecodeError as e: return MsigSent(ok: false, error: "not a public lez-msig instruction: " & e.msg)
  except CatchableError as e: return MsigSent(ok: false, error: "could not prepare the transaction: " & e.msg)
  try:
    let got = c.rpc.sendTransaction(txBytes)
    if got != want: return MsigSent(ok: false, error: "the sequencer answered hash " & got & " for " & want)
  except CatchableError as e: return MsigSent(ok: false, error: e.msg)
  c.sent[want] = epochTime()
  MsigSent(ok: true, hash: want)

method included*(c: MsigLive, hash: string): bool = c.rpc.getTransaction(hash).known
