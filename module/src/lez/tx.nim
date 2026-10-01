## LEZ public transactions, as bytes: v0.2.4 (exo-3c9: the live binding) and, below,
## v0.3.0 (exo-eb6.4 L3), the line the testnet runs since 2026-09-30. The v0.2.4 encoder
## stays for the local v0.2.4 line until the LEZ multisig and FROST move.
##
## What a member's multisig transaction IS on the chain the testnet runs, pinned to
## logos-execution-zone v0.2.4 (lee/state_machine/src/{public_transaction,signature,
## encoding}, lee_core program::InstructionData) and to lez-multisig's multisig_core
## Instruction (feat/lee-v0.2.4, logos-co/lez-multisig#45). The vectors come from those
## crates themselves (tests/vectors/lez-tx-v024).
##
##   instruction  risc0 serde words: an enum is its variant index, a byte one word, a u64
##                two (low, high), a Vec its length then its items, [u8; 32] 32 words
##   Message      borsh { program_id: [u32; 8], account_ids: Vec<[u8; 32]>,
##                        nonces: Vec<u128>, instruction_data: Vec<u32> }
##   hash         SHA-256("/LEE/v0.3/Message/Public/" padded to 32 ‖ borsh(Message))
##   witness      Vec<(BIP-340 signature [u8; 64], x-only public key [u8; 32])>
##   transaction  borsh { message, witness_set }; its hash is SHA-256 of that borsh
##   on the wire  LeeTransaction::Public = 0x00 ‖ borsh(tx), base64 (sendTransaction)
##
## Encoding only: nothing here signs or touches the network. The signing chain is
## wallet/lez_multisig_live.nim, with the member's key in the keystore.

import std/[strutils, options]
import stint
import ../hashing/sha256
import ./multisig
import ./multisig_chain

const
  AccountIdPrefix = "/LEE/v0.3/AccountId/Public/"   ## zero-padded to 32 bytes
  MessagePrefix = "/LEE/v0.3/Message/Public/"       ## zero-padded to 32 bytes

type
  LezMessage* = object
    program*: seq[byte]           ## the [u32; 8] program id as its little-endian bytes (32)
    accounts*: seq[seq[byte]]     ## 32-byte account ids, in the order the program reads them
    nonces*: seq[UInt128]         ## one per signer, in witness order
    words*: seq[uint32]           ## the instruction, as risc0 serde words

  LezWitness* = object
    signature*: seq[byte]         ## BIP-340, 64 bytes
    xonly*: seq[byte]             ## the signer's x-only public key, 32 bytes

proc padded(s: string): seq[byte] =
  doAssert s.len <= 32
  result = newSeq[byte](32)
  for i, c in s: result[i] = byte(c)

proc need32(b: seq[byte], what: string) =
  if b.len != 32: raise newException(ValueError, what & " must be 32 bytes, got " & $b.len)

proc publicAccountId*(xonly: seq[byte]): seq[byte] =
  ## A public account's id from its BIP-340 x-only key (lee: From<&PublicKey> for AccountId).
  need32(xonly, "an x-only key")
  @(sha256(padded(AccountIdPrefix) & xonly))

# ── account ids on the wire: base58 (the JSON-RPC form) ───────────────────────
const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

proc accountIdToBase58*(id: seq[byte]): string =
  need32(id, "an account id")
  var digits: seq[int]                              # base 58, least significant first
  for b in id:
    var carry = int(b)
    for j in 0 ..< digits.len:
      carry += digits[j] * 256
      digits[j] = carry mod 58
      carry = carry div 58
    while carry > 0:
      digits.add carry mod 58
      carry = carry div 58
  for b in id:
    if b != 0: break
    result.add '1'
  for i in countdown(digits.high, 0): result.add B58[digits[i]]

proc accountIdFromBase58*(s: string): seq[byte] =
  ## Raises ValueError unless `s` is base58 for exactly 32 bytes.
  if s.len == 0: raise newException(ValueError, "an empty account id")
  var bytes: seq[int]                               # base 256, least significant first
  for c in s:
    let d = B58.find(c)
    if d < 0: raise newException(ValueError, "not base58: " & s)
    var carry = d
    for j in 0 ..< bytes.len:
      carry += bytes[j] * 58
      bytes[j] = carry and 0xff
      carry = carry shr 8
    while carry > 0:
      bytes.add carry and 0xff
      carry = carry shr 8
  for c in s:
    if c != '1': break
    result.add 0
  for i in countdown(bytes.high, 0): result.add byte(bytes[i])
  if result.len != 32: raise newException(ValueError, "not a 32-byte account id: " & s)

# ── risc0 serde words ─────────────────────────────────────────────────────────
proc wU8(w: var seq[uint32], x: int) =
  if x < 0 or x > 255: raise newException(ValueError, "not a u8: " & $x)
  w.add uint32(x)
proc wU64(w: var seq[uint32], x: uint64) =
  w.add uint32(x and 0xffff_ffff'u64)
  w.add uint32(x shr 32)
proc wBytes32(w: var seq[uint32], b: seq[byte]) =
  need32(b, "a 32-byte field")
  for x in b: w.add uint32(x)
proc wVecBytes32(w: var seq[uint32], xs: seq[seq[byte]]) =
  w.add uint32(xs.len)
  for x in xs: w.wBytes32(x)
proc wVecU32(w: var seq[uint32], xs: seq[uint32]) =
  w.add uint32(xs.len)
  for x in xs: w.add x
proc wVecU8(w: var seq[uint32], xs: seq[uint8]) =
  w.add uint32(xs.len)
  for x in xs: w.add uint32(x)
proc wProgram(w: var seq[uint32], program: seq[byte]) =
  ## A ProgramId ([u32; 8]) from its little-endian bytes.
  need32(program, "a program id")
  for i in 0 ..< 8:
    w.add uint32(program[4*i]) or (uint32(program[4*i+1]) shl 8) or
          (uint32(program[4*i+2]) shl 16) or (uint32(program[4*i+3]) shl 24)

proc instructionWords*(op: MultisigOp, layout: ProposalLayout): seq[uint32] =
  ## multisig_core::Instruction for `op`, as the program reads it. The layout is the
  ## program build's: count-only (c45100b) has no target_account_ids in Propose.
  var w: seq[uint32]
  case op.kind
  of moCreate:
    w.add 0
    w.wBytes32(op.createKey)
    w.wU8(op.threshold)
    w.wVecBytes32(op.members)
  of moPropose:
    let a = op.action
    w.add 1
    w.wProgram(a.target)
    w.wVecU32(a.instruction)
    w.wU8(a.targetAccountCount)
    if layout == plAccountIds: w.wVecBytes32(a.accounts)
    w.wVecBytes32(a.pdaSeeds)
    w.wVecU8(a.authorized)
    w.wBytes32(op.createKey)
    w.wU64(op.index)
  of moApprove, moReject, moExecute:
    w.add(case op.kind
          of moApprove: 2'u32
          of moReject: 3'u32
          else: 4'u32)
    w.wU64(op.index)
    w.wBytes32(op.createKey)
  of moProposeConfig:
    case op.config.kind
    of caAddMember:
      w.add 5
      w.wBytes32(op.config.member)
    of caRemoveMember:
      w.add 6
      w.wBytes32(op.config.member)
    of caChangeThreshold:
      w.add 7
      w.wU8(op.config.threshold)
    w.wBytes32(op.createKey)
    w.wU64(op.index)
  w

proc opSigned*(op: MultisigOp): bool =
  ## Whether the instruction needs a member's signature. A create claims fresh member
  ## accounts and is signed by nobody.
  op.kind != moCreate

proc opAccounts*(scheme: PdaScheme, program: seq[byte], op: MultisigOp, signer: seq[byte]): seq[seq[byte]] =
  ## The accounts the program reads, in its #[account] order (multisig_program/src/lib.rs).
  let state = statePda(scheme, program, op.createKey)
  case op.kind
  of moCreate: @[state] & op.members
  of moExecute: @[state, signer, proposalPda(scheme, program, op.createKey, op.index)] & op.accounts
  else: @[state, signer, proposalPda(scheme, program, op.createKey, op.index)]

# ── borsh ─────────────────────────────────────────────────────────────────────
proc bU32(b: var seq[byte], x: uint32) =
  for i in 0 ..< 4: b.add byte((x shr (8*i)) and 0xff)

proc messageBorsh*(m: LezMessage): seq[byte] =
  need32(m.program, "a program id")
  result.add m.program                         # [u32; 8], each little-endian = its LE bytes
  result.bU32(uint32(m.accounts.len))
  for a in m.accounts:
    need32(a, "an account id")
    result.add a
  result.bU32(uint32(m.nonces.len))
  for n in m.nonces: result.add @(n.toBytesLE())
  result.bU32(uint32(m.words.len))
  for x in m.words: result.bU32(x)

proc messageHash*(m: LezMessage): array[32, byte] =
  ## What each signer signs.
  sha256(padded(MessagePrefix) & messageBorsh(m))

proc publicTxBorsh*(m: LezMessage, witnesses: seq[LezWitness]): seq[byte] =
  result = messageBorsh(m)
  result.bU32(uint32(witnesses.len))
  for w in witnesses:
    if w.signature.len != 64: raise newException(ValueError, "a signature must be 64 bytes")
    need32(w.xonly, "an x-only key")
    result.add w.signature
    result.add w.xonly

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

proc publicTxHash*(m: LezMessage, witnesses: seq[LezWitness]): string =
  ## The transaction's hash as the chain reports it (lowercase hex).
  hexOf(sha256(publicTxBorsh(m, witnesses)))

proc leeTxPublic*(m: LezMessage, witnesses: seq[LezWitness]): seq[byte] =
  ## LeeTransaction::Public: what sendTransaction carries (base64 of these bytes).
  @[0'u8] & publicTxBorsh(m, witnesses)

proc deployBorsh(bytecode: seq[byte]): seq[byte] =
  result.bU32(uint32(bytecode.len))
  result.add bytecode

proc leeTxDeploy*(bytecode: seq[byte]): seq[byte] =
  ## LeeTransaction::ProgramDeployment: unsigned, only the bytecode.
  @[2'u8] & deployBorsh(bytecode)

proc deployTxHash*(bytecode: seq[byte]): string =
  hexOf(sha256(deployBorsh(bytecode)))

# ── LEZ v0.3.0 (exo-eb6.4 L3) ─────────────────────────────────────────────────
# Pinned to logos-execution-zone v0.3.0 (lee/state_machine/src/public_transaction,
# fees.rs; lee_core account::ProgramShardSelector, native_token) and held to
# tests/vectors/lez-tx-v030, from those crates themselves.
#
#   Message      borsh { program_account_id: [u8; 32],
#                        shard_selectors: Vec<{ account_id: [u8; 32], program_account_id: [u8; 32] }>,
#                        nonces: Vec<u128>, instruction_data: Vec<u8> (borsh of the instruction),
#                        fee: Option<{ payer: [u8; 32], gas_limit: u64, tip: u64, max_fee: u128 }> }
#   hash         SHA-256("/LEE/v0.3/Message/Public/" padded ‖ borsh(Message)), as in v0.2.4
#   witness      Vec<(BIP-340 [u8; 64], x-only key [u8; 32])>: every signer, the fee payer
#                included (a co-signing payer's nonce follows the others)
#   transaction  borsh { message, witness_set }; hash SHA-256 of it; LeeTransaction::Public
#                = 0x00 ‖ that, base64 on the wire

const
  NativeTokenProgram* = newSeq[byte](32)
    ## the reserved native token program's account: all zero (lee_core NATIVE_TOKEN_PROGRAM_ID)
  DefaultGasLimit* = 2_000_000'u64
    ## the LEZ wallet's DEFAULT_GAS_LIMIT (lez/wallet/src/lib.rs @ v0.3.0)
  AssumedDataBytes = 100_000'u64
  AssumedBaseFee = 64'u64
    ## the LEZ wallet sizes max_fee as (gas_limit + 100_000) × 64: 8× the genesis minimum
    ## base fee, so a declaration survives early congestion. Unused fee is refunded.

type
  LezShard* = object
    account*: seq[byte]           ## 32-byte account id
    program*: seq[byte]           ## the program whose shard of that account the call sees

  LezFee* = object
    payer*: seq[byte]             ## the account debited; it signs, as every signer does
    gasLimit*: uint64
    tip*: uint64
    maxFee*: UInt128              ## the cap on the fee reservation; the payer must cover it

  LezMessage3* = object
    programAccount*: seq[byte]    ## the program called, by account id (32)
    shards*: seq[LezShard]        ## the rows it reads, in its order
    nonces*: seq[UInt128]         ## one per signer, in witness order (a co-signing payer last)
    instruction*: seq[byte]       ## the instruction, borsh
    fee*: Option[LezFee]          ## none only for system transactions

proc nativeShard*(account: seq[byte]): LezShard =
  ## An account's native-balance shard (ProgramShardSelector::native_balance).
  need32(account, "an account id")
  LezShard(account: account, program: NativeTokenProgram)

proc nativeTransfer*(amount: UInt128): seq[byte] =
  ## The native token program's instruction: borsh Transfer { amount: u128 } (variant 0).
  @[0'u8] & @(amount.toBytesLE())

proc defaultFee*(payer: seq[byte]): LezFee =
  ## The LEZ wallet's own default declaration: gas 2_000_000, tip 0,
  ## max_fee (gas + 100_000) × 64 = 134_400_000.
  need32(payer, "a fee payer")
  LezFee(payer: payer, gasLimit: DefaultGasLimit, tip: 0,
         maxFee: ((DefaultGasLimit + AssumedDataBytes) * AssumedBaseFee).stuint(128))

proc bU64(b: var seq[byte], x: uint64) =
  for i in 0 ..< 8: b.add byte((x shr (8*i)) and 0xff)

proc messageBorsh*(m: LezMessage3): seq[byte] =
  need32(m.programAccount, "a program account id")
  result.add m.programAccount
  result.bU32(uint32(m.shards.len))
  for s in m.shards:
    need32(s.account, "an account id")
    need32(s.program, "a program account id")
    result.add s.account
    result.add s.program
  result.bU32(uint32(m.nonces.len))
  for n in m.nonces: result.add @(n.toBytesLE())
  result.bU32(uint32(m.instruction.len))
  result.add m.instruction
  if m.fee.isNone: result.add 0'u8
  else:
    let f = m.fee.get
    need32(f.payer, "a fee payer")
    result.add 1'u8
    result.add f.payer
    result.bU64(f.gasLimit)
    result.bU64(f.tip)
    result.add @(f.maxFee.toBytesLE())

proc messageHash*(m: LezMessage3): array[32, byte] =
  ## What each signer signs, the fee payer included.
  sha256(padded(MessagePrefix) & messageBorsh(m))

proc publicTxBorsh*(m: LezMessage3, witnesses: seq[LezWitness]): seq[byte] =
  result = messageBorsh(m)
  result.bU32(uint32(witnesses.len))
  for w in witnesses:
    if w.signature.len != 64: raise newException(ValueError, "a signature must be 64 bytes")
    need32(w.xonly, "an x-only key")
    result.add w.signature
    result.add w.xonly

proc publicTxHash*(m: LezMessage3, witnesses: seq[LezWitness]): string =
  ## The transaction's hash as the chain reports it (lowercase hex).
  hexOf(sha256(publicTxBorsh(m, witnesses)))

proc leeTxPublic*(m: LezMessage3, witnesses: seq[LezWitness]): seq[byte] =
  ## LeeTransaction::Public: what sendTransaction carries (base64 of these bytes).
  @[0'u8] & publicTxBorsh(m, witnesses)
