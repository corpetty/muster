## The LEZ multisig program's on-chain objects as muster reads them (exo-a26, Phase C1).
## Layouts pinned to logos-co/lez-multisig @ c45100b (multisig_core/src/lib.rs); PDA
## derivation to spel-framework-core v0.3.0 (pda.rs) and to logos-execution-zone
## (nssa v0.2.0-rc3 nssa/core/src/program.rs; LEE v0.2.5-rc2
## lee/state_machine/core/src/program/mod.rs). Upstream publishes no fixed-output PDA
## vectors, so the derivation is pinned to the formula as read; the live binding (exo-3c9)
## is where a real chain arbitrates.
##   1. MultisigState is borsh: create_key · threshold u8 · member_count u8 · members
##      (u32 length + 32 bytes each) · transaction_index u64 LE — exact bytes, round trip;
##   2. Proposal is borsh in field order, the ProgramId as 8 little-endian u32 words, the
##      instruction as u32 words, the status a one-byte variant, the config action an
##      Option of a one-byte-tagged enum — exact bytes, round trip, every variant;
##   3. a truncated or over-long account is refused — never a partial read;
##   4. SPEL seeds: a string is zero-padded to 32 bytes (never longer), a u64 is its LE
##      bytes zero-padded, one seed is used as is, several are SHA-256(seed1 || seed2 …);
##   5. a public PDA is SHA-256(prefix || program || seed) with the scheme's own prefix —
##      "/NSSA/v0.2/AccountId/PDA/" for the published program (rc3), "/LEE/v0.2/AccountId/
##      PDA/" for LEE v0.2.5 — so the two schemes give different addresses for one program;
##      the state, proposal and vault PDAs are the program's own seed lists;
##   6. a Proposal / MultisigState model: the proposer auto-approves, one approval per
##      member, approving clears a rejection (and back), has-threshold and is-dead.
## Pure Nim (sha256 only).

import std/[strutils, sequtils]
import ../src/hashing/sha256
import ../src/lez/multisig

proc b32(x: byte): seq[byte] = newSeqWith(32, x)
proc le32(x: uint32): seq[byte] = @[byte(x and 0xff), byte((x shr 8) and 0xff), byte((x shr 16) and 0xff), byte(x shr 24)]
proc le64(x: uint64): seq[byte] =
  for i in 0 ..< 8: result.add byte((x shr uint64(8*i)) and 0xff)

let K = b32(7)
let (A, B, C) = (b32(1), b32(2), b32(3))

# ── 1. MultisigState ───────────────────────────────────────────────────────────
block:
  let st = MultisigState(createKey: K, threshold: 2, members: @[A, B, C], transactionIndex: 5)
  let bytes = encodeState(st)
  doAssert bytes == K & @[2'u8, 3'u8] & le32(3) & A & B & C & le64(5), "borsh field order and widths"
  let back = decodeState(bytes)
  doAssert back.createKey == K and back.threshold == 2 and back.members == @[A, B, C] and back.transactionIndex == 5
  doAssert back.memberCount == 3
  echo "1. MultisigState: exact borsh bytes, round trip OK"

# ── 2. Proposal ────────────────────────────────────────────────────────────────
block:
  let prog = toSeq(0'u8 .. 31'u8)
  var p = newProposal(1, A, K, LezAction(target: prog, instruction: @[1'u32, 500, 0x0403_0201],
                      accountCount: 2, pdaSeeds: @[b32(9)], authorized: @[0'u8]))
  p.approved.add B
  p.rejected.add C
  let bytes = encodeProposal(p)
  let want = le64(1) & A & K & prog &
             le32(3) & le32(1) & le32(500) & le32(0x0403_0201) &
             @[2'u8] & le32(1) & b32(9) & le32(1) & @[0'u8] &
             le32(2) & A & B & le32(1) & C &
             @[0'u8] & @[0'u8]                     # Active · no config action
  doAssert bytes == want, "borsh: " & $bytes.len & " vs " & $want.len
  let back = decodeProposal(bytes)
  doAssert back.index == 1 and back.proposer == A and back.createKey == K
  doAssert back.action.target == prog and back.action.instruction == @[1'u32, 500, 0x0403_0201]
  doAssert back.action.accountCount == 2 and back.action.pdaSeeds == @[b32(9)] and back.action.authorized == @[0'u8]
  doAssert back.approved == @[A, B] and back.rejected == @[C] and back.status == psActive and not back.hasConfig
  for (s, tag) in [(psActive, 0'u8), (psExecuted, 1'u8), (psRejected, 2'u8), (psCancelled, 3'u8)]:
    var q = p
    q.status = s
    doAssert encodeProposal(q)[^2] == tag and decodeProposal(encodeProposal(q)).status == s
  let add = newConfigProposal(2, A, K, ConfigAction(kind: caAddMember, member: b32(4)))
  doAssert encodeProposal(add)[^34 .. ^1] == @[1'u8, 0'u8] & b32(4), "Some(AddMember{new_member})"
  doAssert add.action.target == newSeq[byte](32) and add.action.instruction.len == 0, "a config proposal calls nothing"
  let rm = newConfigProposal(3, A, K, ConfigAction(kind: caRemoveMember, member: C))
  doAssert encodeProposal(rm)[^34 .. ^1] == @[1'u8, 1'u8] & C
  let th = newConfigProposal(4, A, K, ConfigAction(kind: caChangeThreshold, threshold: 3))
  doAssert encodeProposal(th)[^3 .. ^1] == @[1'u8, 2'u8, 3'u8]
  for q in [add, rm, th]:
    let d = decodeProposal(encodeProposal(q))
    doAssert d.hasConfig and d.config == q.config
  echo "2. Proposal: exact borsh bytes, every status and config action, round trip OK"

# ── 3. refused reads ───────────────────────────────────────────────────────────
block:
  let p = encodeProposal(newProposal(1, A, K, LezAction(target: b32(5), accountCount: 1)))
  for bad in [p[0 ..< p.len - 1], p & @[0'u8], newSeq[byte](0)]:
    var raised = false
    try: discard decodeProposal(bad)
    except LezDecodeError: raised = true
    doAssert raised, "a partial or padded account is refused"
  var raised = false
  try: discard decodeState(encodeState(MultisigState(createKey: K, threshold: 1, members: @[A]))[0 ..< 40])
  except LezDecodeError: raised = true
  doAssert raised
  echo "3. truncated or over-long accounts are refused OK"

# ── 4. SPEL seeds ──────────────────────────────────────────────────────────────
block:
  doAssert seedFromStr("multisig_prop___") == cast[seq[byte]]("multisig_prop___") & newSeq[byte](16)
  var raised = false
  try: discard seedFromStr(repeat("x", 33))
  except LezDecodeError: raised = true
  doAssert raised, "a seed string over 32 bytes is refused"
  doAssert seedU64(0x0102030405060708'u64) == @[8'u8, 7, 6, 5, 4, 3, 2, 1] & newSeq[byte](24)
  doAssert combineSeeds(@[K]) == K, "one seed is used as is"
  doAssert combineSeeds(@[b32(1), b32(2)]) == @(sha256(b32(1) & b32(2))), "several are hashed together"
  doAssert combineSeeds(@[b32(1), b32(2)]) != combineSeeds(@[b32(2), b32(1)]), "order matters"
  doAssert vaultSeed(K) == @(sha256(seedFromStr("multisig_vault__") & K))
  echo "4. SPEL seeds: padded strings, LE integers, one seed as is, several hashed in order OK"

# ── 5. PDAs, per scheme ────────────────────────────────────────────────────────
block:
  let prog = b32(0xAA)
  let nssa = cast[seq[byte]]("/NSSA/v0.2/AccountId/PDA/") & newSeq[byte](7)
  let lee = cast[seq[byte]]("/LEE/v0.2/AccountId/PDA/") & newSeq[byte](8)
  doAssert nssa.len == 32 and lee.len == 32
  doAssert publicPda(psNssa02, prog, K) == @(sha256(nssa & prog & K))
  doAssert publicPda(psLee02, prog, K) == @(sha256(lee & prog & K))
  doAssert statePda(psLee02, prog, K) == publicPda(psLee02, prog, K), "state: [arg(create_key)] — one seed"
  doAssert proposalPda(psLee02, prog, K, 3) ==
           publicPda(psLee02, prog, combineSeeds(@[seedFromStr("multisig_prop___"), K, seedU64(3)]))
  doAssert vaultPda(psLee02, prog, K) == publicPda(psLee02, prog, vaultSeed(K))
  doAssert statePda(psNssa02, prog, K) != statePda(psLee02, prog, K), "the two chains give different addresses"
  doAssert proposalPda(psLee02, prog, K, 1) != proposalPda(psLee02, prog, K, 2)
  doAssert $psNssa02 == "nssa-v0.2" and $psLee02 == "lee-v0.2" and parsePdaScheme("lee-v0.2") == psLee02
  echo "5. PDAs: SHA-256(prefix || program || seed), per scheme; state / proposal / vault seed lists OK"

# ── 6. the voting model ────────────────────────────────────────────────────────
block:
  var p = newProposal(1, A, K, LezAction(target: b32(5), accountCount: 1))
  doAssert p.approved == @[A], "the proposer auto-approves"
  doAssert p.approve(B) and not p.approve(B), "one approval per member"
  doAssert p.reject(B) and p.approved == @[A] and p.rejected == @[B], "rejecting withdraws the approval"
  doAssert p.approve(B) and p.rejected.len == 0, "and approving withdraws the rejection"
  doAssert p.hasThreshold(2) and not p.hasThreshold(3)
  var q = newProposal(2, A, K, LezAction(target: b32(5), accountCount: 1))
  discard q.reject(B)
  doAssert not q.isDead(2, 3) and q.reject(C) and q.isDead(2, 3), "rejections ≥ n − k + 1 kill it"
  echo "6. the voting model: auto-approve, one vote per member, flips, threshold, dead OK"

echo "lez_multisig_model_test: the program's state, proposals and PDAs as muster reads them — all OK"
