## lez-msig's bytes in Nim (epic exo-0d3, docs/design/lez-msig.md §3–§5): the types the
## program stores and its members sign, their borsh, the tagged hashes a signature covers, and
## the multisig's public PDA. The rules themselves live in the program's own core
## (programs/lez-msig/core): muster re-derives what a member signs and checks a signature
## against a member's disclosed key, and the program's own check is the one that counts.
##
## Held byte for byte to tests/vectors/lez-msig/vectors.json, which the program's host
## generates (programs/lez-msig/host/src/bin/msig_vectors.rs).

import std/[json, options, sequtils, strutils]
import stint
import ../hashing/sha256
import ../bitcoin/keys as btckeys
import ./multisig

type
  Key32* = seq[byte]                ## an account, a program, a zone tag, an x-only key (32)
  MsigDecodeError* = object of ValueError

const
  RolePropose* = 1'u8
  RoleApprove* = 2'u8
  RoleExecute* = 4'u8
  RoleAll* = RolePropose or RoleApprove or RoleExecute
  ActTransfer* = 1'u8
  ActCall* = 2'u8
  ActAll* = ActTransfer or ActCall
  NonceWindow* = 256'u64
  TagProposal = "muster-msig/v1/proposal"
  TagApprove = "muster-msig/v1/approve"
  TagExecute = "muster-msig/v1/execute"
  TagSpend = "muster-msig/v1/spend"
  TagStateSeed = "muster-msig/v1/state"

type
  MsigMember* = object
    key*: Key32
    roles*: uint8
    weight*: uint16

  MsigLimit* = object
    id*: uint32
    signers*: seq[Key32]
    threshold*: uint8
    amount*: UInt128
    periodMs*: uint64

  MsigConfig* = object
    members*: seq[MsigMember]
    threshold*: uint32
    timelockMs*: uint64
    openExecution*: bool
    actions*: uint8
    targets*: seq[Key32]
    limits*: seq[MsigLimit]

  MsigUsage* = object
    id*: uint32
    period*: uint64
    used*: UInt128

  MsigQueued* = object
    nonce*: uint64
    proposalId*: Key32
    etaMs*: uint64
    expiresMs*: uint64

  MsigState* = object
    version*: uint8
    zone*: Key32
    createKey*: Key32
    epoch*: uint64
    config*: MsigConfig
    usage*: seq[MsigUsage]
    nonceBase*: uint64
    consumed*: seq[byte]           ## 32 bytes: the nonce window's bitmap
    queue*: seq[MsigQueued]

  ChangeKind* = enum
    ccAddMember, ccRemoveMember, ccSetRoles, ccSetWeight, ccSetThreshold, ccSetTimelock,
    ccSetOpenExecution, ccSetActions, ccSetTargets, ccAddLimit, ccRemoveLimit

  MsigChange* = object
    case kind*: ChangeKind
    of ccAddMember: member*: MsigMember
    of ccRemoveMember: removed*: Key32
    of ccSetRoles:
      rolesKey*: Key32
      roles*: uint8
    of ccSetWeight:
      weightKey*: Key32
      weight*: uint16
    of ccSetThreshold: threshold*: uint32
    of ccSetTimelock: timelockMs*: uint64
    of ccSetOpenExecution: open*: bool
    of ccSetActions: actions*: uint8
    of ccSetTargets: targets*: seq[Key32]
    of ccAddLimit: limit*: MsigLimit
    of ccRemoveLimit: limitId*: uint32

  MsigRow* = object
    account*: Key32
    program*: Key32

  ActionKind* = enum akTransfer, akCall, akConfig, akCancel

  MsigAction* = object
    case kind*: ActionKind
    of akTransfer:
      to*: Key32
      amount*: UInt128
    of akCall:
      program*: Key32
      rows*: seq[MsigRow]
      data*: seq[byte]
    of akConfig: changes*: seq[MsigChange]
    of akCancel: nonces*: seq[uint64]

  MsigProposal* = object
    multisig*: Key32
    zone*: Key32
    epoch*: uint64
    nonce*: uint64
    action*: MsigAction
    expiresMs*: uint64
    proposer*: Key32

  MsigSpend* = object
    multisig*, zone*: Key32
    epoch*: uint64
    limit*: uint32
    nonce*: uint64
    to*: Key32
    amount*: UInt128
    expiresMs*: uint64

  MsigSigned* = object
    key*: Key32
    sig*: seq[byte]                ## 64

  InstrKind* = enum ikCreate, ikExecute, ikQueue, ikExecuteQueued, ikSpend

  MsigInstruction* = object
    case kind*: InstrKind
    of ikCreate:
      zone*: Key32
      config*: MsigConfig
    of ikExecute, ikQueue, ikExecuteQueued:
      proposal*: MsigProposal
      approvals*: seq[MsigSigned]  ## empty for ExecuteQueued (not encoded there)
      executor*: Option[MsigSigned]
      atMs*: uint64                ## Queue and ExecuteQueued only
    of ikSpend:
      spend*: MsigSpend
      spendApprovals*: seq[MsigSigned]
      period*: uint64
      periodMs*: uint64

proc bad(msg: string) {.noreturn.} = raise newException(MsigDecodeError, msg)
proc need32(b: seq[byte], what: string) =
  if b.len != 32: raise newException(ValueError, what & " must be 32 bytes, not " & $b.len)

# ── borsh, out ───────────────────────────────────────────────────────────────
proc u8(b: var seq[byte], x: uint8) = b.add x
proc u16(b: var seq[byte], x: uint16) =
  for i in 0 ..< 2: b.add byte((x shr (8*i)) and 0xff)
proc u32(b: var seq[byte], x: uint32) =
  for i in 0 ..< 4: b.add byte((x shr (8*i)) and 0xff)
proc u64(b: var seq[byte], x: uint64) =
  for i in 0 ..< 8: b.add byte((x shr (8*i)) and 0xff)
proc u128(b: var seq[byte], x: UInt128) = b.add @(x.toBytesLE())
proc k32(b: var seq[byte], k: Key32, what = "a 32-byte key") =
  need32(k, what)
  b.add k
proc keys(b: var seq[byte], ks: seq[Key32]) =
  b.u32(uint32(ks.len))
  for k in ks: b.k32(k)
proc bytesVec(b: var seq[byte], xs: seq[byte]) =
  b.u32(uint32(xs.len))
  b.add xs

proc enc(b: var seq[byte], m: MsigMember) =
  b.k32(m.key, "a member key"); b.u8(m.roles); b.u16(m.weight)
proc enc(b: var seq[byte], l: MsigLimit) =
  b.u32(l.id); b.keys(l.signers); b.u8(l.threshold); b.u128(l.amount); b.u64(l.periodMs)
proc enc(b: var seq[byte], c: MsigConfig) =
  b.u32(uint32(c.members.len))
  for m in c.members: b.enc(m)
  b.u32(c.threshold); b.u64(c.timelockMs); b.u8(uint8(c.openExecution)); b.u8(c.actions)
  b.keys(c.targets)
  b.u32(uint32(c.limits.len))
  for l in c.limits: b.enc(l)
proc enc(b: var seq[byte], c: MsigChange) =
  b.u8(uint8(ord(c.kind)))
  case c.kind
  of ccAddMember: b.enc(c.member)
  of ccRemoveMember: b.k32(c.removed)
  of ccSetRoles: b.k32(c.rolesKey); b.u8(c.roles)
  of ccSetWeight: b.k32(c.weightKey); b.u16(c.weight)
  of ccSetThreshold: b.u32(c.threshold)
  of ccSetTimelock: b.u64(c.timelockMs)
  of ccSetOpenExecution: b.u8(uint8(c.open))
  of ccSetActions: b.u8(c.actions)
  of ccSetTargets: b.keys(c.targets)
  of ccAddLimit: b.enc(c.limit)
  of ccRemoveLimit: b.u32(c.limitId)
proc enc(b: var seq[byte], a: MsigAction) =
  b.u8(uint8(ord(a.kind)))
  case a.kind
  of akTransfer: b.k32(a.to); b.u128(a.amount)
  of akCall:
    b.k32(a.program)
    b.u32(uint32(a.rows.len))
    for r in a.rows: b.k32(r.account); b.k32(r.program)
    b.bytesVec(a.data)
  of akConfig:
    b.u32(uint32(a.changes.len))
    for c in a.changes: b.enc(c)
  of akCancel:
    b.u32(uint32(a.nonces.len))
    for n in a.nonces: b.u64(n)
proc enc(b: var seq[byte], p: MsigProposal) =
  b.k32(p.multisig); b.k32(p.zone); b.u64(p.epoch); b.u64(p.nonce); b.enc(p.action)
  b.u64(p.expiresMs); b.k32(p.proposer)
proc enc(b: var seq[byte], s: MsigSpend) =
  b.k32(s.multisig); b.k32(s.zone); b.u64(s.epoch); b.u32(s.limit); b.u64(s.nonce); b.k32(s.to)
  b.u128(s.amount); b.u64(s.expiresMs)
proc enc(b: var seq[byte], s: MsigSigned) =
  b.k32(s.key)
  if s.sig.len != 64: raise newException(ValueError, "a signature is 64 bytes")
  b.add s.sig
proc encSigned(b: var seq[byte], xs: seq[MsigSigned]) =
  b.u32(uint32(xs.len))
  for x in xs: b.enc(x)
proc encOpt(b: var seq[byte], x: Option[MsigSigned]) =
  if x.isNone: b.u8(0)
  else:
    b.u8(1); b.enc(x.get)
proc enc(b: var seq[byte], i: MsigInstruction) =
  b.u8(uint8(ord(i.kind)))
  case i.kind
  of ikCreate: b.k32(i.zone); b.enc(i.config)
  of ikExecute: b.enc(i.proposal); b.encSigned(i.approvals); b.encOpt(i.executor)
  of ikQueue: b.enc(i.proposal); b.encSigned(i.approvals); b.encOpt(i.executor); b.u64(i.atMs)
  of ikExecuteQueued: b.enc(i.proposal); b.encOpt(i.executor); b.u64(i.atMs)
  of ikSpend: b.enc(i.spend); b.encSigned(i.spendApprovals); b.u64(i.period); b.u64(i.periodMs)

proc `==`*(a, b: MsigChange): bool =
  ## Equal exactly when their bytes are: what a signature covers is the only identity.
  var x, y: seq[byte]
  x.enc(a); y.enc(b)
  x == y
proc `==`*(a, b: MsigAction): bool =
  var x, y: seq[byte]
  x.enc(a); y.enc(b)
  x == y
proc `==`*(a, b: MsigProposal): bool =
  var x, y: seq[byte]
  x.enc(a); y.enc(b)
  x == y
proc borsh*(c: MsigConfig): seq[byte] = result.enc(c)
proc borsh*(p: MsigProposal): seq[byte] = result.enc(p)
proc borsh*(s: MsigSpend): seq[byte] = result.enc(s)
proc borsh*(i: MsigInstruction): seq[byte] = result.enc(i)

proc envelopePublic*(createKey: Key32, op: MsigInstruction): seq[byte] =
  ## The program's instruction for a multisig over a public PDA: msig_v03's
  ## ProgramInstruction { create_key, placement: Public, op }. A private multisig's envelope
  ## carries its group's keys and is built by the prover, never here.
  result.k32(createKey, "a create key")
  result.u8(0)
  result.enc(op)

# ── borsh, in (the state, as the chain holds it) ─────────────────────────────
type Reader = object
  b: seq[byte]
  i: int
proc need(r: Reader, n: int) =
  if r.i + n > r.b.len: bad("the state ends early")
proc ru8(r: var Reader): uint8 =
  r.need(1); result = r.b[r.i]; inc r.i
proc ru16(r: var Reader): uint16 =
  r.need(2)
  for k in 0 ..< 2: result = result or (uint16(r.b[r.i+k]) shl (8*k))
  r.i += 2
proc ru32(r: var Reader): uint32 =
  r.need(4)
  for k in 0 ..< 4: result = result or (uint32(r.b[r.i+k]) shl (8*k))
  r.i += 4
proc ru64(r: var Reader): uint64 =
  r.need(8)
  for k in 0 ..< 8: result = result or (uint64(r.b[r.i+k]) shl (8*k))
  r.i += 8
proc ru128(r: var Reader): UInt128 =
  r.need(16)
  result = UInt128.fromBytesLE(r.b[r.i ..< r.i+16])
  r.i += 16
proc rfixed(r: var Reader, n: int): seq[byte] =
  r.need(n); result = r.b[r.i ..< r.i+n]; r.i += n
proc rlen(r: var Reader, each: int): int =
  let n = int(r.ru32())
  if n * each > r.b.len - r.i: bad("a length runs past the state")
  n
proc rbool(r: var Reader): bool =
  case r.ru8()
  of 0: false
  of 1: true
  else: bad("not a bool")
proc rkeys(r: var Reader): seq[Key32] =
  for _ in 0 ..< r.rlen(32): result.add r.rfixed(32)
proc rmember(r: var Reader): MsigMember =
  MsigMember(key: r.rfixed(32), roles: r.ru8(), weight: r.ru16())
proc rlimit(r: var Reader): MsigLimit =
  MsigLimit(id: r.ru32(), signers: r.rkeys(), threshold: r.ru8(), amount: r.ru128(), periodMs: r.ru64())
proc rconfig(r: var Reader): MsigConfig =
  for _ in 0 ..< r.rlen(35): result.members.add r.rmember()
  result.threshold = r.ru32(); result.timelockMs = r.ru64(); result.openExecution = r.rbool()
  result.actions = r.ru8(); result.targets = r.rkeys()
  for _ in 0 ..< r.rlen(1): result.limits.add r.rlimit()

proc rchange(r: var Reader): MsigChange =
  let tag = r.ru8()
  if tag > uint8(ord(high(ChangeKind))): bad("unknown config change " & $tag)
  case ChangeKind(tag)
  of ccAddMember: MsigChange(kind: ccAddMember, member: r.rmember())
  of ccRemoveMember: MsigChange(kind: ccRemoveMember, removed: r.rfixed(32))
  of ccSetRoles: MsigChange(kind: ccSetRoles, rolesKey: r.rfixed(32), roles: r.ru8())
  of ccSetWeight: MsigChange(kind: ccSetWeight, weightKey: r.rfixed(32), weight: r.ru16())
  of ccSetThreshold: MsigChange(kind: ccSetThreshold, threshold: r.ru32())
  of ccSetTimelock: MsigChange(kind: ccSetTimelock, timelockMs: r.ru64())
  of ccSetOpenExecution: MsigChange(kind: ccSetOpenExecution, open: r.rbool())
  of ccSetActions: MsigChange(kind: ccSetActions, actions: r.ru8())
  of ccSetTargets: MsigChange(kind: ccSetTargets, targets: r.rkeys())
  of ccAddLimit: MsigChange(kind: ccAddLimit, limit: r.rlimit())
  of ccRemoveLimit: MsigChange(kind: ccRemoveLimit, limitId: r.ru32())

proc raction(r: var Reader): MsigAction =
  let tag = r.ru8()
  if tag > uint8(ord(high(ActionKind))): bad("unknown action " & $tag)
  case ActionKind(tag)
  of akTransfer: MsigAction(kind: akTransfer, to: r.rfixed(32), amount: r.ru128())
  of akCall:
    var a = MsigAction(kind: akCall, program: r.rfixed(32))
    for _ in 0 ..< r.rlen(64): a.rows.add MsigRow(account: r.rfixed(32), program: r.rfixed(32))
    a.data = r.rfixed(r.rlen(1))
    a
  of akConfig:
    var a = MsigAction(kind: akConfig)
    for _ in 0 ..< r.rlen(1): a.changes.add r.rchange()
    a
  of akCancel:
    var a = MsigAction(kind: akCancel)
    for _ in 0 ..< r.rlen(8): a.nonces.add r.ru64()
    a

proc decodeProposal*(b: openArray[byte]): MsigProposal =
  ## A proposal as its members sign it. Only exact bytes decode: a short, padded or
  ## non-canonical encoding (a bool other than 0/1, a trailing byte) is refused.
  var r = Reader(b: @b)
  result.multisig = r.rfixed(32); result.zone = r.rfixed(32); result.epoch = r.ru64()
  result.nonce = r.ru64(); result.action = r.raction(); result.expiresMs = r.ru64()
  result.proposer = r.rfixed(32)
  if r.i != r.b.len: bad("trailing bytes after the proposal")

proc decodeMsigConfig*(b: openArray[byte]): MsigConfig =
  var r = Reader(b: @b)
  result = r.rconfig()
  if r.i != r.b.len: bad("trailing bytes after the config")

proc decodeMsigState*(b: openArray[byte]): MsigState =
  ## The program's shard of the multisig's account. A partial or padded shard is refused.
  var r = Reader(b: @b)
  result.version = r.ru8()
  if result.version != 1: bad("unknown state version " & $result.version)
  result.zone = r.rfixed(32); result.createKey = r.rfixed(32); result.epoch = r.ru64()
  result.config = r.rconfig()
  for _ in 0 ..< r.rlen(28): result.usage.add MsigUsage(id: r.ru32(), period: r.ru64(), used: r.ru128())
  result.nonceBase = r.ru64(); result.consumed = r.rfixed(32)
  for _ in 0 ..< r.rlen(56):
    result.queue.add MsigQueued(nonce: r.ru64(), proposalId: r.rfixed(32), etaMs: r.ru64(), expiresMs: r.ru64())
  if r.i != r.b.len: bad("trailing bytes after the state")

# ── a private note (exo-efa): the multisig's account as a member decrypts it ──────────
type
  MsigNote* = object
    nonce*: UInt128
    shards*: seq[tuple[program, data: seq[byte]]]   ## by program account id, ascending

proc decodeNote*(b: openArray[byte]): MsigNote =
  ## lee_core's Account, borsh: {nonce: u128, data: {shards: BTreeMap<AccountId, Vec<u8>>}}.
  var r = Reader(b: @b)
  result.nonce = r.ru128()
  for _ in 0 ..< r.rlen(36):
    let prog = r.rfixed(32)
    result.shards.add (prog, r.rfixed(r.rlen(1)))
  if r.i != r.b.len: bad("trailing bytes after the note")

proc noteState*(n: MsigNote, program: Key32): Option[MsigState] =
  ## The multisig's state: the program's own shard of its note.
  for (p, d) in n.shards:
    if p == program and d.len > 0: return some(decodeMsigState(d))

proc noteBalance*(n: MsigNote): UInt128 =
  ## The vault: the note's native shard (u128 LE), 0 when it has none.
  for (p, d) in n.shards:
    if p == newSeq[byte](32) and d.len == 16: return UInt128.fromBytesLE(d)

proc encodeMsigState*(s: MsigState): seq[byte] =
  ## For in-process models and tests; the chain's bytes come from the program.
  var b: seq[byte]
  b.u8(s.version); b.k32(s.zone); b.k32(s.createKey); b.u64(s.epoch); b.enc(s.config)
  b.u32(uint32(s.usage.len))
  for u in s.usage: b.u32(u.id); b.u64(u.period); b.u128(u.used)
  b.u64(s.nonceBase)
  if s.consumed.len != 32: raise newException(ValueError, "the bitmap is 32 bytes")
  b.add s.consumed
  b.u32(uint32(s.queue.len))
  for q in s.queue: b.u64(q.nonce); b.k32(q.proposalId); b.u64(q.etaMs); b.u64(q.expiresMs)
  b

# ── what a signature covers (§4) ─────────────────────────────────────────────
proc bytesOf(s: string): seq[byte] =
  for c in s: result.add byte(c)

proc tagged*(tag: string, msg: openArray[byte]): seq[byte] =
  ## BIP-340's tagged hash: SHA256(SHA256(tag) ‖ SHA256(tag) ‖ msg).
  let t = @(sha256(bytesOf(tag)))
  @(sha256(t & t & @msg))

proc proposalId*(p: MsigProposal): seq[byte] = tagged(TagProposal, borsh(p))
proc approveMsg*(proposalId: seq[byte]): seq[byte] = tagged(TagApprove, proposalId)
proc executeMsg*(proposalId: seq[byte]): seq[byte] = tagged(TagExecute, proposalId)
proc spendMsg*(s: MsigSpend): seq[byte] = tagged(TagSpend, borsh(s))
proc stateSeed*(createKey: Key32): seq[byte] = tagged(TagStateSeed, createKey)

proc multisigPublic*(program, createKey: Key32): Key32 =
  ## The multisig's account over a public PDA: for_public_pda(program, state seed).
  publicPda(psLee02, program, stateSeed(createKey))

proc verifySig*(key, msg, sig: openArray[byte]): bool =
  ## BIP-340, as the program checks it.
  sig.len == 64 and key.len == 32 and btckeys.schnorrVerify(sig, msg, key)

# ── the tally the room shows (the program's check is the one that counts) ─────
proc memberOf*(c: MsigConfig, key: Key32): Option[MsigMember] =
  for m in c.members:
    if m.key == key: return some(m)

proc approvalWeight*(c: MsigConfig, signers: seq[Key32]): uint32 =
  ## The APPROVE weight of distinct current members among `signers`.
  var seen: seq[Key32]
  for k in signers:
    if k in seen: continue
    seen.add k
    let m = c.memberOf(k)
    if m.isSome and (m.get.roles and RoleApprove) != 0: result += uint32(m.get.weight)

proc nonceFree*(s: MsigState, n: uint64): bool =
  if n < s.nonceBase or n - s.nonceBase >= NonceWindow: return false
  let off = n - s.nonceBase
  (s.consumed[int(off div 8)] and (1'u8 shl (off mod 8))) == 0

proc nextNonce*(s: MsigState, taken: seq[uint64] = @[]): uint64 =
  ## The lowest nonce still free in the window and not already `taken` by a proposal in the
  ## room.
  var n = s.nonceBase
  while n < s.nonceBase + NonceWindow:
    if s.nonceFree(n) and n notin taken: return n
    inc n
  raise newException(ValueError, "the nonce window is full: execute or cancel a proposal first")

proc hexOf*(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

# ── what the card shows, decoded from the bytes the approvals sign (RFP U.6) ─────
proc rolesText*(r: uint8): seq[string] =
  if (r and RolePropose) != 0: result.add "propose"
  if (r and RoleApprove) != 0: result.add "approve"
  if (r and RoleExecute) != 0: result.add "execute"

proc memberJson(m: MsigMember): JsonNode =
  %*{"key": hexOf(m.key), "roles": rolesText(m.roles), "weight": int(m.weight)}

proc limitJson(l: MsigLimit): JsonNode =
  %*{"id": int(l.id), "signers": l.signers.mapIt(hexOf(it)), "threshold": int(l.threshold),
     "amount": $l.amount, "periodMs": $l.periodMs}

proc changeJson*(c: MsigChange): JsonNode =
  case c.kind
  of ccAddMember: %*{"change": "add-member", "member": memberJson(c.member)}
  of ccRemoveMember: %*{"change": "remove-member", "key": hexOf(c.removed)}
  of ccSetRoles: %*{"change": "set-roles", "key": hexOf(c.rolesKey), "roles": rolesText(c.roles)}
  of ccSetWeight: %*{"change": "set-weight", "key": hexOf(c.weightKey), "weight": int(c.weight)}
  of ccSetThreshold: %*{"change": "set-threshold", "threshold": int(c.threshold)}
  of ccSetTimelock: %*{"change": "set-timelock", "timelockMs": $c.timelockMs}
  of ccSetOpenExecution: %*{"change": "set-open-execution", "open": c.open}
  of ccSetActions: %*{"change": "set-actions", "transfer": (c.actions and ActTransfer) != 0,
                      "call": (c.actions and ActCall) != 0}
  of ccSetTargets: %*{"change": "set-targets", "targets": c.targets.mapIt(hexOf(it))}
  of ccAddLimit: %*{"change": "add-limit", "limit": limitJson(c.limit)}
  of ccRemoveLimit: %*{"change": "remove-limit", "id": int(c.limitId)}

proc actionJson*(a: MsigAction): JsonNode =
  case a.kind
  of akTransfer: %*{"kind": "transfer", "to": hexOf(a.to), "amount": $a.amount}
  of akCall: %*{"kind": "call", "program": hexOf(a.program),
                "rows": a.rows.mapIt(%*{"account": hexOf(it.account), "program": hexOf(it.program)}),
                "data": hexOf(a.data)}
  of akConfig: %*{"kind": "config", "changes": a.changes.mapIt(changeJson(it))}
  of akCancel: %*{"kind": "cancel", "nonces": a.nonces.mapIt($it)}

proc proposalJson*(p: MsigProposal): JsonNode =
  %*{"multisig": hexOf(p.multisig), "zone": hexOf(p.zone), "epoch": $p.epoch, "nonce": $p.nonce,
     "action": actionJson(p.action), "expiresMs": $p.expiresMs, "proposer": hexOf(p.proposer),
     "proposalId": hexOf(proposalId(p))}

proc configJson*(c: MsigConfig): JsonNode =
  %*{"members": c.members.mapIt(memberJson(it)), "threshold": int(c.threshold),
     "timelockMs": $c.timelockMs, "openExecution": c.openExecution,
     "transfer": (c.actions and ActTransfer) != 0, "call": (c.actions and ActCall) != 0,
     "targets": c.targets.mapIt(hexOf(it)), "limits": c.limits.mapIt(limitJson(it))}

# ── a config change, as the program applies it (core/src/rules.rs apply_changes) ──
proc applyChanges*(c: MsigConfig, changes: seq[MsigChange]): MsigConfig =
  ## The config after an executed config change, or a ValueError naming why the program would
  ## refuse it. The room folds executed changes with this; the chain's own state is what
  ## settlement re-reads, and the program's check is the one that counts. The checks are the
  ## program's, except that a key is not checked to be a curve point (it was one when added).
  result = c
  for ch in changes:
    case ch.kind
    of ccAddMember:
      if result.memberOf(ch.member.key).isSome: raise newException(ValueError, "member keys must be distinct")
      result.members.add ch.member
    of ccRemoveMember:
      if result.memberOf(ch.removed).isNone: raise newException(ValueError, "not a member: " & hexOf(ch.removed))
      if result.limits.anyIt(ch.removed in it.signers):
        raise newException(ValueError, "a spending limit's signer: remove the limit first")
      result.members = result.members.filterIt(it.key != ch.removed)
    of ccSetRoles, ccSetWeight:
      let k = (if ch.kind == ccSetRoles: ch.rolesKey else: ch.weightKey)
      var found = false
      for m in result.members.mitems:
        if m.key == k:
          found = true
          if ch.kind == ccSetRoles: m.roles = ch.roles else: m.weight = ch.weight
      if not found: raise newException(ValueError, "not a member: " & hexOf(k))
    of ccSetThreshold: result.threshold = ch.threshold
    of ccSetTimelock: result.timelockMs = ch.timelockMs
    of ccSetOpenExecution: result.openExecution = ch.open
    of ccSetActions: result.actions = ch.actions
    of ccSetTargets: result.targets = ch.targets
    of ccAddLimit: result.limits.add ch.limit
    of ccRemoveLimit:
      let before = result.limits.len
      result.limits = result.limits.filterIt(it.id != ch.limitId)
      if result.limits.len == before: raise newException(ValueError, "unknown spending limit " & $ch.limitId)
  let r = result
  if r.members.len == 0 or r.members.len > 32: raise newException(ValueError, "between 1 and 32 members")
  for i, m in r.members:
    if r.members[0 ..< i].anyIt(it.key == m.key): raise newException(ValueError, "member keys must be distinct")
    if m.weight == 0: raise newException(ValueError, "every weight is at least 1")
    if m.roles == 0 or (m.roles and not RoleAll) != 0: raise newException(ValueError, "every member holds a known role")
  if r.threshold == 0 or r.threshold > approvalWeight(r, r.members.mapIt(it.key)):
    raise newException(ValueError, "the threshold is between 1 and the approvers' total weight")
  if not r.members.anyIt((it.roles and RolePropose) != 0): raise newException(ValueError, "someone must be able to propose")
  if not r.openExecution and not r.members.anyIt((it.roles and RoleExecute) != 0):
    raise newException(ValueError, "someone must be able to execute")
