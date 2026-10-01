## The LEZ multisig chain seam, and an in-process model of the program (exo-946, Phase C2).
##
## What muster needs from a chain running logos-co/lez-multisig, and nothing more:
##   readAccount(id)           — an account's bytes (borsh), its owner, at a height
##   submit(signer, op, payer) — a MEMBER's transaction: create / propose / approve /
##                               reject / execute. The member's LEZ wallet signs it; muster
##                               holds no LEZ key and never signs (invariant 3). `payer` is
##                               the funded account of theirs that pays the fee — the
##                               program claims member accounts fresh, so they cannot.
##   txIncluded(hash)          — did it land, and where
## It is a ChainAdapter too, so the settlement seam can hold it: a prepared Execute
## submits from the relayer (`<member>:<payer>`), finality is read from the chain.
##
## FakeLezMultisig reproduces the program's handlers (multisig_program/src/*.rs @
## c45100b): the same checks, in the same order, with the program's own messages, over
## accounts stored as the program's borsh bytes at their PDAs — so muster's read path
## decodes real layouts. A refused transaction is not included: it changes nothing and
## charges nothing. The live binding over lez_core is exo-3c9.
##
## With layout v0.3 it reproduces the v0.3 port instead (plan/apply, exo-eb6.4.4), and the
## v0.3 chain's rule for a refusal: the transaction is INCLUDED, keeps its fee and burns
## its signer's nonce, and nothing else changes — `submit` answers ok, as the real chain's
## sequencer does, and the program's reason is kept in `lastRefusal` (the real chain does not
## say it). Every v0.3 op is signed by its sender, who pays its own fee. An Execute whose call
## is a native transfer out of the vault moves the fake's balances.

import std/[json, tables, strutils, sequtils]
import stint
import ../hashing/sha256
import ../crypto/keystore
import ../wallet/types
import ../wallet/adapter
import ./multisig

type
  MultisigOpKind* = enum
    moCreate = "create", moPropose = "propose", moProposeConfig = "propose-config",
    moApprove = "approve", moReject = "reject", moExecute = "execute",
    moExecuteConfig = "execute-config"   ## v0.3: ExecuteConfig is its own instruction

  MultisigOp* = object
    kind*: MultisigOpKind
    createKey*: seq[byte]
    threshold*: int               ## create
    members*: seq[seq[byte]]      ## create
    index*: uint64                ## propose (the next index) / vote / execute
    action*: LezAction            ## propose
    config*: ConfigAction         ## propose-config
    accounts*: seq[seq[byte]]     ## execute: the target accounts, in order
    approvers*: seq[seq[byte]]    ## v0.3 execute / execute-config: the approvals it counts

  LezTx* = object
    ok*: bool
    hash*: string                 ## 64 hex
    error*: string                ## the program's refusal when not ok
    height*: uint64

  LezRead* = object
    found*: bool
    data*: seq[byte]
    owner*: seq[byte]             ## the owning program ("" = none)
    height*: uint64               ## the chain height the read was taken at
    nonce*: UInt128               ## the account's nonce (how many transactions it signed)
    balance*: UInt128             ## its native balance

  ChainedCallRecord* = object
    program*: seq[byte]
    instruction*: seq[uint32]
    accounts*: seq[seq[byte]]
    authorized*: seq[uint8]
    pdaSeeds*: seq[seq[byte]]
    data*: seq[byte]              ## v0.3: the call's borsh instruction

  LezMultisigChain* = ref object of ChainAdapter
    chain*: string                ## CAIP-2, e.g. "lez:testnet"
    scheme*: PdaScheme
    program*: seq[byte]           ## the program's 32-byte identity in the scheme
    layout*: ProposalLayout       ## how this program build lays a proposal out

proc createOp*(createKey: seq[byte], threshold: int, members: seq[seq[byte]]): MultisigOp =
  MultisigOp(kind: moCreate, createKey: createKey, threshold: threshold, members: members)
proc proposeOp*(createKey: seq[byte], index: uint64, action: LezAction): MultisigOp =
  MultisigOp(kind: moPropose, createKey: createKey, index: index, action: action)
proc proposeConfigOp*(createKey: seq[byte], index: uint64, cfg: ConfigAction): MultisigOp =
  MultisigOp(kind: moProposeConfig, createKey: createKey, index: index, config: cfg)
proc approveOp*(createKey: seq[byte], index: uint64): MultisigOp =
  MultisigOp(kind: moApprove, createKey: createKey, index: index)
proc rejectOp*(createKey: seq[byte], index: uint64): MultisigOp =
  MultisigOp(kind: moReject, createKey: createKey, index: index)
proc executeOp*(createKey: seq[byte], index: uint64, accounts: seq[seq[byte]]): MultisigOp =
  MultisigOp(kind: moExecute, createKey: createKey, index: index, accounts: accounts)
proc executeOpV03*(createKey: seq[byte], index: uint64, approvers: seq[seq[byte]], call: LezAction): MultisigOp =
  ## v0.3: Execute names the approvers it counts and carries the call (what the proposal
  ## must commit to); its rows are the state, the proposal, then the call's rows.
  MultisigOp(kind: moExecute, createKey: createKey, index: index, approvers: approvers, action: call,
             accounts: call.accounts)
proc executeConfigOp*(createKey: seq[byte], index: uint64, approvers: seq[seq[byte]], cfg: ConfigAction): MultisigOp =
  MultisigOp(kind: moExecuteConfig, createKey: createKey, index: index, approvers: approvers, config: cfg)

method height*(c: LezMultisigChain): uint64 {.base.} =
  raise newException(WalletError, "LezMultisigChain.height is abstract")
method readAccount*(c: LezMultisigChain, id: seq[byte]): LezRead {.base.} =
  raise newException(WalletError, "LezMultisigChain.readAccount is abstract")
method submit*(c: LezMultisigChain, signer: seq[byte], op: MultisigOp, payer: seq[byte] = @[]): LezTx {.base.} =
  raise newException(WalletError, "LezMultisigChain.submit is abstract")
method txIncluded*(c: LezMultisigChain, hash: string): tuple[known: bool, height: uint64] {.base.} =
  raise newException(WalletError, "LezMultisigChain.txIncluded is abstract")
method sendWitnessed*(c: LezMultisigChain, program: seq[byte], accounts, signers: seq[seq[byte]],
                      words: seq[uint32], witnesses: seq[(seq[byte], seq[byte])]): LezTx {.base.} =
  ## A public transaction whose witnesses (signature, x-only key) someone already made,
  ## e.g. a FROST aggregate (lez.frost-public-account). The live chain sends it.
  raise newException(WalletError, "LezMultisigChain.sendWitnessed is abstract")
method sendBuilt*(c: LezMultisigChain, leeTx: seq[byte], hash: string): LezTx {.base.} =
  ## A transaction someone already built and witnessed, as the bytes sendTransaction
  ## carries, and the hash it must answer with: the v0.3.0 line's (exo-eb6.4 L3), whose
  ## message lez/tx.nim builds. The live chain sends it and awaits it.
  raise newException(WalletError, "LezMultisigChain.sendBuilt is abstract")

proc readState*(c: LezMultisigChain, createKey: seq[byte]): tuple[found: bool, state: MultisigState, height: uint64] =
  ## The multisig's state, decoded from its PDA; raises LezDecodeError on a malformed account.
  let r = c.readAccount(statePda(c.scheme, c.program, createKey))
  if not r.found: return (false, MultisigState(), r.height)
  (true, decodeState(r.data), r.height)

proc readProposal*(c: LezMultisigChain, createKey: seq[byte], index: uint64): tuple[found: bool, proposal: Proposal, height: uint64] =
  let r = c.readAccount(proposalPda(c.scheme, c.program, createKey, index))
  if not r.found: return (false, Proposal(), r.height)
  (true, decodeProposal(r.data, c.layout), r.height)

# ── hex helpers ───────────────────────────────────────────────────────────────
proc hx(b: seq[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))
proc unhx(s: string): seq[byte] =
  var h = s.strip()
  if h.len >= 2 and h[0] == '0' and h[1] in {'x', 'X'}: h = h[2 .. ^1]
  if h.len mod 2 != 0: raise newException(WalletError, "odd-length hex: " & s)
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except ValueError: raise newException(WalletError, "bad hex: " & s)

proc relayerParts*(id: string): tuple[signer, payer: seq[byte]] =
  ## A LEZ relayer account id is "<member hex>" or "<member hex>:<payer hex>".
  let i = id.find(':')
  if i < 0: (unhx(id), newSeq[byte]())
  else: (unhx(id[0 ..< i]), unhx(id[i+1 .. ^1]))

# ── the ChainAdapter face (what the settlement seam holds) ────────────────────
method describe*(c: LezMultisigChain): ChainDescriptor =
  let native = AssetId(chain: c.chain, symbol: "LEZ", kind: akNative, decimals: 9)
  ChainDescriptor(chain: c.chain, displayName: "Logos Execution Zone (" & c.chain & ")",
                  nativeAsset: native, accountForms: @[afPublic], finality: finImmediate)

method accounts*(c: LezMultisigChain, ks: Keystore): seq[Account] = @[]
method assets*(c: LezMultisigChain): seq[AssetId] = @[c.describe().nativeAsset]
method estimateFee*(c: LezMultisigChain, frm: Account, to: string, amt: Amount): FeeEstimate =
  raise newException(WalletError, "a multisig vote's fee is its own transaction's")
method prepareTransfer*(c: LezMultisigChain, frm: Account, to: string, amt: Amount): PreparedTx =
  raise newException(WalletError, "a multisig spends by proposal, not by transfer")

method submit*(c: LezMultisigChain, tx: PreparedTx, ks: Keystore): TxRef =
  ## A prepared multisig transaction ({op: execute, createKey, index, accounts}) from the
  ## relayer member; a refusal raises — never a false landed.
  var op: MultisigOp
  try:
    let p = parseJson(tx.payload)
    if p{"op"}.getStr() != "execute": raise newException(WalletError, "only a prepared execute is submitted here")
    if p{"lez"}.getStr() == "v0.3":
      let c = p["call"]
      var shards: seq[tuple[account, program: seq[byte]]]
      for x in c["shards"]: shards.add (unhx(x["account"].getStr()), unhx(x["program"].getStr()))
      op = executeOpV03(unhx(p{"createKey"}.getStr()), uint64(p{"index"}.getBiggestInt()),
                        p["approvers"].getElems().mapIt(unhx(it.getStr())),
                        lezCallV03(unhx(c["target"].getStr()), shards, unhx(c["data"].getStr()),
                                   c["pdaSeeds"].getElems().mapIt(unhx(it.getStr()))))
    else:
      op = executeOp(unhx(p{"createKey"}.getStr()), uint64(p{"index"}.getBiggestInt()),
                     p{"accounts"}.getElems().mapIt(unhx(it.getStr())))
  except WalletError as e: raise e
  except CatchableError as e: raise newException(WalletError, "not a LEZ multisig payload: " & e.msg)
  let (signer, payer) = relayerParts(tx.frm.id)
  let r = c.submit(signer, op, payer)
  if not r.ok: raise newException(WalletError, "the chain refused it: " & r.error)
  TxRef(chain: c.chain, id: r.hash)

method finality*(c: LezMultisigChain, txRef: TxRef): Finality =
  let (known, h) = c.txIncluded(txRef.id)
  if known: Finality(status: fsFinal, detail: "included at height " & $h)
  else: Finality(status: fsFailed, detail: "the chain does not know this transaction")

# ── FakeLezMultisig: the program, in process ──────────────────────────────────
type
  FakeAccount = object
    data: seq[byte]
    owner: seq[byte]
    nonce: uint64
    balance: uint64

  FakeLezMultisig* = ref object of LezMultisigChain
    accts: Table[string, FakeAccount]
    txs: Table[string, uint64]
    tip: uint64
    feePerTx*: uint64
    chainedCalls*: seq[ChainedCallRecord]
    lastRefusal*: string          ## v0.3: why the last included transaction changed nothing ("" = it took)

  Refused = object of CatchableError

proc newFakeLezMultisig*(chain: string, scheme: PdaScheme, program: seq[byte], feePerTx = 0'u64,
                         layout = plCountOnly): FakeLezMultisig =
  ## `layout` picks the program build modelled: count-only (the published c45100b, #40
  ## open) or account-ids (the rebuild with #41 — target accounts committed and bound).
  FakeLezMultisig(chain: chain, scheme: scheme, program: program, feePerTx: feePerTx, layout: layout)

proc fund*(f: FakeLezMultisig, acct: seq[byte], amount: uint64) =
  var a = f.accts.getOrDefault(hx(acct))
  a.balance += amount
  f.accts[hx(acct)] = a

proc balanceOf*(f: FakeLezMultisig, acct: seq[byte]): uint64 = f.accts.getOrDefault(hx(acct)).balance

proc isFresh(a: FakeAccount): bool =
  a.data.len == 0 and a.owner.len == 0 and a.nonce == 0 and a.balance == 0

method height*(f: FakeLezMultisig): uint64 = f.tip

method readAccount*(f: FakeLezMultisig, id: seq[byte]): LezRead =
  let k = hx(id)
  if k notin f.accts: return LezRead(found: false, height: f.tip)
  let a = f.accts[k]
  LezRead(found: a.data.len > 0 or a.owner.len > 0, data: a.data, owner: a.owner, height: f.tip, nonce: u128(a.nonce),
          balance: a.balance.stuint(128))

method txIncluded*(f: FakeLezMultisig, hash: string): tuple[known: bool, height: uint64] =
  if hash in f.txs: (true, f.txs[hash]) else: (false, 0'u64)

proc refuse(msg: string) {.noreturn.} = raise newException(Refused, msg)
proc check(cond: bool, msg: string) =
  if not cond: refuse(msg)

proc sameCall(a, b: LezAction): bool =
  a.target == b.target and a.shards == b.shards and a.data == b.data and a.pdaSeeds == b.pdaSeeds

proc nativeTransferAmount(a: LezAction): tuple[ok: bool, amount: uint64] =
  ## A native transfer (the native token program, account 0; borsh Transfer { amount }),
  ## amounts that fit the fake's u64 balances.
  let zero = newSeq[byte](32)
  if a.target != zero or a.shards.len != 2 or a.shards.anyIt(it.program != zero): return
  if a.data.len != 17 or a.data[0] != 0 or a.data[9 .. 16].anyIt(it != 0): return
  var x: uint64
  for i in 0 ..< 8: x = x or (uint64(a.data[1 + i]) shl uint64(8*i))
  (true, x)

proc submitV03(f: FakeLezMultisig, signer: seq[byte], op: MultisigOp): LezTx =
  ## The v0.3 port's plan and apply checks, with its messages (multisig_program/src/lib.rs).
  let sk = hx(signer)
  if f.accts.getOrDefault(sk).balance < f.feePerTx:
    # a payer who cannot cover the fee's reserve: no correct block includes it
    return LezTx(ok: false, error: "the payer cannot cover the fee (" & $f.feePerTx & ")")
  var next = f.accts                               # all-or-nothing: work on a copy
  var calls: seq[ChainedCallRecord]
  proc acct(id: seq[byte]): FakeAccount = next.getOrDefault(hx(id))
  proc put(id: seq[byte], a: FakeAccount) = next[hx(id)] = a
  let stateId = statePda(f.scheme, f.program, op.createKey)
  let propId = proposalPda(f.scheme, f.program, op.createKey, op.index)
  proc loadState(): MultisigState =
    let a = acct(stateId)
    check(a.data.len > 0, "no multisig here")
    decodeState(a.data)
  proc saveState(s: MultisigState) =
    var a = acct(stateId)
    a.data = encodeState(s)
    a.owner = f.program
    put(stateId, a)
  proc loadProposal(): Proposal =
    let a = acct(propId)
    check(a.data.len > 0, "no proposal here")
    decodeProposal(a.data, plV03)
  proc saveProposal(p: Proposal) =
    var a = acct(propId)
    a.data = encodeProposal(p, plV03)
    a.owner = f.program
    put(propId, a)
  proc ownVault(a: LezAction) =
    check(a.pdaSeeds.allIt(it == vaultSeed(op.createKey)), "a proposal may authorize only its own multisig's vault")
  proc quorum(s: MultisigState, approvers: seq[seq[byte]]) =
    for i, a in approvers:
      check(a notin approvers[0 ..< i], "an approver is named twice")
      check(a in s.members, "an approver is not a current member")
    check(approvers.len >= s.threshold, "fewer approvers than the threshold")
  var refusal = ""
  try:
    case op.kind
    of moCreate:
      check(op.members.len in 1 .. 10, "1 to 10 members")
      for i, m in op.members: check(m notin op.members[0 ..< i], "a member appears twice")
      check(op.threshold >= 1 and op.threshold <= op.members.len, "1 ≤ threshold ≤ members")
      check(acct(stateId).data.len == 0, "a multisig already exists here")
      saveState(MultisigState(createKey: op.createKey, threshold: op.threshold, members: op.members))
    of moPropose, moProposeConfig:
      if op.kind == moPropose: ownVault(op.action)
      elif op.config.kind == caChangeThreshold: check(op.config.threshold >= 1, "a threshold is at least 1")
      var s = loadState()
      check(signer in s.members, "the proposer is not a member")
      check(op.index == s.transactionIndex + 1, "not the next proposal index")
      check(acct(propId).data.len == 0, "a proposal already exists here")
      s.transactionIndex = op.index
      saveState(s)
      saveProposal(if op.kind == moPropose: newProposal(op.index, signer, op.createKey, op.action)
                   else: newConfigProposal(op.index, signer, op.createKey, op.config))
    of moApprove, moReject:
      let s = loadState()
      check(signer in s.members, "the voter is not a member")
      var p = loadProposal()
      check(p.status == psActive, "the proposal is no longer active")
      if op.kind == moApprove: check(p.approve(signer), "already approved")
      else: check(p.reject(signer), "already rejected")
      saveProposal(p)
    of moExecute:
      ownVault(op.action)
      quorum(loadState(), op.approvers)
      var p = loadProposal()
      check(p.status == psActive, "the proposal is no longer active")
      check(not p.hasConfig and sameCall(p.action, op.action), "not the call this proposal commits to")
      for a in op.approvers: check(a in p.approved, "a named approver did not approve this proposal")
      p.status = psExecuted
      saveProposal(p)
      calls.add ChainedCallRecord(program: op.action.target, accounts: op.action.shards.mapIt(it.account),
                                  pdaSeeds: op.action.pdaSeeds, data: op.action.data)
      let (native, amount) = nativeTransferAmount(op.action)
      if native:
        let (src, dst) = (op.action.shards[0].account, op.action.shards[1].account)
        check(src == vaultPda(f.scheme, f.program, op.createKey), "native transfer sender is not authorized")
        var a = acct(src)
        check(a.balance >= amount, "sender holds less than the transferred amount")
        a.balance -= amount
        put(src, a)
        var b = acct(dst)
        b.balance += amount
        put(dst, b)
    of moExecuteConfig:
      var s = loadState()
      quorum(s, op.approvers)
      case op.config.kind
      of caAddMember:
        check(op.config.member notin s.members, "already a member")
        check(s.members.len < 10, "at most 10 members")
        s.members.add op.config.member
      of caRemoveMember:
        check(op.config.member in s.members, "not a member")
        check(s.members.len > s.threshold, "removing a member would leave fewer members than the threshold")
        s.members.keepItIf(it != op.config.member)
      of caChangeThreshold:
        check(op.config.threshold >= 1 and op.config.threshold <= s.members.len, "1 ≤ threshold ≤ members")
        s.threshold = op.config.threshold
      saveState(s)
      var p = loadProposal()
      check(p.status == psActive, "the proposal is no longer active")
      check(p.hasConfig and p.config == op.config, "not the call this proposal commits to")
      for a in op.approvers: check(a in p.approved, "a named approver did not approve this proposal")
      p.status = psExecuted
      saveProposal(p)
  except Refused as e: refusal = e.msg
  except LezDecodeError as e: refusal = "not a multisig account: " & e.msg
  # included either way: the signer pays its fee and its nonce advances; a refusal keeps
  # nothing else (v0.3: "a failed action is ordinary execution semantics")
  if refusal.len > 0: next = f.accts
  var sa = next.getOrDefault(sk)
  sa.balance -= f.feePerTx
  inc sa.nonce
  next[sk] = sa
  f.accts = next
  f.lastRefusal = refusal
  inc f.tip
  if refusal.len == 0: f.chainedCalls.add calls
  var h: seq[byte]
  for b in sk & ":v0.3:" & $op.kind & ":" & $op.index & ":" & $f.tip & ":" & $sa.nonce: h.add byte(b)
  let hash = hx(@(sha256(h)))
  f.txs[hash] = f.tip
  LezTx(ok: true, hash: hash, height: f.tip)

method submit*(f: FakeLezMultisig, signer: seq[byte], op: MultisigOp, payer: seq[byte] = @[]): LezTx =
  let payerKey = hx(if payer.len > 0: payer else: signer)
  if f.layout == plV03: return f.submitV03(signer, op)
  if f.accts.getOrDefault(payerKey).balance < f.feePerTx:
    return LezTx(ok: false, error: "the payer cannot cover the fee (" & $f.feePerTx & ")")
  var next = f.accts                               # all-or-nothing: work on a copy
  var calls: seq[ChainedCallRecord]
  proc acct(id: seq[byte]): FakeAccount = next.getOrDefault(hx(id))
  proc put(id: seq[byte], a: FakeAccount) = next[hx(id)] = a
  let stateId = statePda(f.scheme, f.program, op.createKey)
  proc loadState(): MultisigState =
    let a = acct(stateId)
    check(a.owner == f.program and a.data.len > 0, "multisig state not found")
    decodeState(a.data)
  proc saveState(s: MultisigState) =
    var a = acct(stateId)
    a.data = encodeState(s)
    put(stateId, a)
  let propId = proposalPda(f.scheme, f.program, op.createKey, op.index)
  proc loadProposal(s: MultisigState): Proposal =
    let a = acct(propId)
    check(a.owner == f.program and a.data.len > 0, "proposal #" & $op.index & " not found")
    result = decodeProposal(a.data, f.layout)
    check(result.createKey == s.createKey, "Proposal does not belong to this multisig")
    check(result.status == psActive, "Proposal is not active")
  proc saveProposal(p: Proposal) =
    var a = acct(propId)
    a.data = encodeProposal(p, f.layout)
    a.owner = f.program
    put(propId, a)
  try:
    case op.kind
    of moCreate:
      check(op.members.len > 0, "Multisig must have at least one member")
      check(op.threshold >= 1, "Threshold must be at least 1")
      check(op.threshold <= op.members.len, "Threshold cannot exceed member count")
      check(op.members.len <= 10, "Maximum 10 members for PoC")
      check(acct(stateId).owner.len == 0, "the multisig state account already exists (create_key in use)")
      for i, m in op.members:
        check(acct(m).isFresh, "Member account " & $i & " must be uninitialized (fresh keypair required)")
      put(stateId, FakeAccount(owner: f.program))
      saveState(MultisigState(createKey: op.createKey, threshold: op.threshold, members: op.members))
      for m in op.members:
        var a = acct(m)
        a.owner = f.program                                   # claimed by the program
        put(m, a)
    of moPropose, moProposeConfig:
      var s = loadState()
      check(s.members.contains(signer), "Proposer is not a multisig member")
      check(op.index == s.transactionIndex + 1,
            "the proposal index must be the next one (#" & $(s.transactionIndex + 1) & ")")
      check(acct(propId).owner.len == 0, "Proposal account must be uninitialized")
      if op.kind == moProposeConfig:
        case op.config.kind
        of caAddMember:
          check(not s.members.contains(op.config.member), "Account is already a member")
          check(s.members.len < 10, "Maximum 10 members")
        of caRemoveMember: check(s.members.contains(op.config.member), "Account is not a member")
        of caChangeThreshold: check(op.config.threshold >= 1, "Threshold must be at least 1")
      elif f.layout == plAccountIds:
        # #41: the committed id list must cover exactly the declared targets
        check(op.action.accounts.len == op.action.targetAccountCount,
              "target_account_ids length (" & $op.action.accounts.len & ") must equal target_account_count (" &
              $op.action.targetAccountCount & ")")
      inc s.transactionIndex
      saveState(s)
      saveProposal(if op.kind == moPropose: newProposal(s.transactionIndex, signer, s.createKey, op.action)
                   else: newConfigProposal(s.transactionIndex, signer, s.createKey, op.config))
    of moApprove:
      let s = loadState()
      check(s.members.contains(signer), "Approver is not a multisig member")
      var p = loadProposal(s)
      check(p.approve(signer), "Member has already approved this proposal")
      saveProposal(p)
    of moReject:
      let s = loadState()
      check(s.members.contains(signer), "Rejector is not a multisig member")
      var p = loadProposal(s)
      check(p.reject(signer), "Member has already rejected this proposal")
      if p.isDead(s.threshold, s.memberCount): p.status = psRejected
      saveProposal(p)
    of moExecute:
      var s = loadState()
      check(s.members.contains(signer), "Executor is not a multisig member")
      var p = loadProposal(s)
      check(p.hasThreshold(s.threshold), "Proposal has not reached threshold (" & $s.threshold &
                                         " needed, " & $p.approved.len & " approved)")
      p.status = psExecuted
      if p.hasConfig:
        check(op.accounts.len == 0, "a config proposal takes no target accounts")
        case p.config.kind
        of caAddMember:
          check(not s.members.contains(p.config.member), "Account is already a member")
          check(s.members.len < 10, "Maximum 10 members")
          s.members.add p.config.member
        of caRemoveMember:
          check(s.members.contains(p.config.member), "Account is not a member")
          check(s.members.len - 1 >= s.threshold, "Cannot remove member: would make member count (" &
                $(s.members.len - 1) & ") less than threshold (" & $s.threshold & ")")
          s.members.keepItIf(it != p.config.member)
        of caChangeThreshold:
          check(p.config.threshold >= 1, "Threshold must be at least 1")
          check(p.config.threshold <= s.members.len, "Threshold (" & $p.config.threshold &
                ") cannot exceed member count (" & $s.members.len & ")")
          s.threshold = p.config.threshold
        saveState(s)
      else:
        check(op.accounts.len == p.action.accountCount,
              "Expected " & $p.action.accountCount & " target accounts, got " & $op.accounts.len)
        if f.layout == plAccountIds:
          # #41: bind every supplied account to the one the members approved
          for i, acct in op.accounts:
            check(acct == p.action.accounts[i], "Target account " & $i & " does not match the approved proposal")
        calls.add ChainedCallRecord(program: p.action.target, instruction: p.action.instruction,
                                    accounts: op.accounts, authorized: p.action.authorized,
                                    pdaSeeds: p.action.pdaSeeds)
      saveProposal(p)
    of moExecuteConfig: refuse("v0.2.4 executes a config proposal with Execute")
  except Refused as e:
    return LezTx(ok: false, error: e.msg)
  except LezDecodeError as e:
    return LezTx(ok: false, error: "Failed to deserialize: " & e.msg)
  # accepted: charge the payer, bump the signer's nonce, include it in the next block
  var pa = next.getOrDefault(payerKey)
  pa.balance -= f.feePerTx
  next[payerKey] = pa
  var sa = next.getOrDefault(hx(signer))
  inc sa.nonce
  next[hx(signer)] = sa
  f.accts = next
  inc f.tip
  f.chainedCalls.add calls
  var h: seq[byte]
  for b in hx(signer) & ":" & $op.kind & ":" & $op.index & ":" & $f.tip & ":" & $sa.nonce: h.add byte(b)
  let hash = hx(@(sha256(h)))
  f.txs[hash] = f.tip
  LezTx(ok: true, hash: hash, height: f.tip)

method balance*(f: FakeLezMultisig, account: Account, asset: AssetId): Amount =
  Amount(asset: f.describe().nativeAsset, raw: $f.balanceOf(relayerParts(account.id).signer))
