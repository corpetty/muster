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

import std/[json, tables, strutils, sequtils]
import ../hashing/sha256
import ../crypto/keystore
import ../wallet/types
import ../wallet/adapter
import ./multisig

type
  MultisigOpKind* = enum
    moCreate = "create", moPropose = "propose", moProposeConfig = "propose-config",
    moApprove = "approve", moReject = "reject", moExecute = "execute"

  MultisigOp* = object
    kind*: MultisigOpKind
    createKey*: seq[byte]
    threshold*: int               ## create
    members*: seq[seq[byte]]      ## create
    index*: uint64                ## propose (the next index) / vote / execute
    action*: LezAction            ## propose
    config*: ConfigAction         ## propose-config
    accounts*: seq[seq[byte]]     ## execute: the target accounts, in order

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

  ChainedCallRecord* = object
    program*: seq[byte]
    instruction*: seq[uint32]
    accounts*: seq[seq[byte]]
    authorized*: seq[uint8]
    pdaSeeds*: seq[seq[byte]]

  LezMultisigChain* = ref object of ChainAdapter
    chain*: string                ## CAIP-2, e.g. "lez:testnet"
    scheme*: PdaScheme
    program*: seq[byte]           ## the program's 32-byte identity in the scheme

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

method height*(c: LezMultisigChain): uint64 {.base.} =
  raise newException(WalletError, "LezMultisigChain.height is abstract")
method readAccount*(c: LezMultisigChain, id: seq[byte]): LezRead {.base.} =
  raise newException(WalletError, "LezMultisigChain.readAccount is abstract")
method submit*(c: LezMultisigChain, signer: seq[byte], op: MultisigOp, payer: seq[byte] = @[]): LezTx {.base.} =
  raise newException(WalletError, "LezMultisigChain.submit is abstract")
method txIncluded*(c: LezMultisigChain, hash: string): tuple[known: bool, height: uint64] {.base.} =
  raise newException(WalletError, "LezMultisigChain.txIncluded is abstract")

proc readState*(c: LezMultisigChain, createKey: seq[byte]): tuple[found: bool, state: MultisigState, height: uint64] =
  ## The multisig's state, decoded from its PDA; raises LezDecodeError on a malformed account.
  let r = c.readAccount(statePda(c.scheme, c.program, createKey))
  if not r.found: return (false, MultisigState(), r.height)
  (true, decodeState(r.data), r.height)

proc readProposal*(c: LezMultisigChain, createKey: seq[byte], index: uint64): tuple[found: bool, proposal: Proposal, height: uint64] =
  let r = c.readAccount(proposalPda(c.scheme, c.program, createKey, index))
  if not r.found: return (false, Proposal(), r.height)
  (true, decodeProposal(r.data), r.height)

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

  Refused = object of CatchableError

proc newFakeLezMultisig*(chain: string, scheme: PdaScheme, program: seq[byte], feePerTx = 0'u64): FakeLezMultisig =
  FakeLezMultisig(chain: chain, scheme: scheme, program: program, feePerTx: feePerTx)

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
  LezRead(found: a.data.len > 0 or a.owner.len > 0, data: a.data, owner: a.owner, height: f.tip)

method txIncluded*(f: FakeLezMultisig, hash: string): tuple[known: bool, height: uint64] =
  if hash in f.txs: (true, f.txs[hash]) else: (false, 0'u64)

proc refuse(msg: string) {.noreturn.} = raise newException(Refused, msg)
proc check(cond: bool, msg: string) =
  if not cond: refuse(msg)

method submit*(f: FakeLezMultisig, signer: seq[byte], op: MultisigOp, payer: seq[byte] = @[]): LezTx =
  let payerKey = hx(if payer.len > 0: payer else: signer)
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
    result = decodeProposal(a.data)
    check(result.createKey == s.createKey, "Proposal does not belong to this multisig")
    check(result.status == psActive, "Proposal is not active")
  proc saveProposal(p: Proposal) =
    var a = acct(propId)
    a.data = encodeProposal(p)
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
        calls.add ChainedCallRecord(program: p.action.target, instruction: p.action.instruction,
                                    accounts: op.accounts, authorized: p.action.authorized,
                                    pdaSeeds: p.action.pdaSeeds)
      saveProposal(p)
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
