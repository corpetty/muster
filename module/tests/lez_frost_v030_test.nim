## A FROST group's LEZ call on the v0.3.0 line, in the room (exo-eb6.4 L3), with no chain.
## The lez-call effect gains a second version ("lez": "v0.3", schema muster.effect.lez-call.v2)
## carrying exactly what a v0.3 public message commits to:
##   1. the effect names the program account, each row's shard, the instruction bytes, the
##      signer's nonce and the fee declaration; the driver's materialization is the v0.3
##      message hash lez/tx.nim derives from those, and nothing else;
##   2. before anyone signs, the driver refuses a call the group should not sign: another
##      signer, more than one nonce, no instruction, no fee, or a fee someone else pays
##      (the room composes the group paying its own fee; a co-signing payer is not a room
##      path yet);
##   3. the manifest names the program it calls and every row it passes;
##   4. a v1 effect (the v0.2.4 line) still hashes as v0.2.4's message;
##   5. on v0.3 a refused call is still included and pays, and the chain reports no outcome
##      (exo-eb6.4.6), so the group signs only a call whose outcome muster can tell from the
##      chain: a native transfer out of its own account. Settlement then refuses a transfer
##      the account cannot cover with its fee cap at the signed nonce — one it covers can
##      only take effect if included, since nothing but the group's own signature debits it.
## Needs the secp closure + libsodium.

import std/[json, strutils, sequtils, options]
import stint
import ../src/crypto/keystore
import ../src/frost/[secp, chilldkg]
import ../src/intents/materialization
import ../src/drivers/[driver, manifest, lez_frost]
import ../src/coordination/intent_events
import ../src/lez/tx as leztx
import ../src/lez/[multisig, multisig_chain]
import ../src/wallet/types
import ../src/settlement/settlement
import ../src/bitcoin/tx                 # toHex / hexToBytes

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

# a 2-of-3 ceremony, in process: the group and its account
let kss = @[Keystore(newInMemoryKeystore(seed(81), seed(91))), Keystore(newInMemoryKeystore(seed(82), seed(92))),
            Keystore(newInMemoryKeystore(seed(83), seed(93)))]
let L = "lez-frost-v030-unit"
let params = SessionParams(hostpubkeys: kss.mapIt(it.frostHostPubkey(L)), t: 2)
let pm1 = kss.mapIt(it.frostDkgStep1(L, params))
let (cst, cmsg1) = coordinatorStep1(pm1, params)
let pm2 = kss.mapIt(it.frostDkgStep2(L, params, cmsg1))
let (_, _, rec) = coordinatorFinalize(cst, pm2)
let acct = lezFrostAccount("lez:local", rec)
let d = newLezFrostDriver(acct)
let to = publicAccountId(kss[1].lezMemberKey("to"))
let other = publicAccountId(kss[2].lezMemberKey("other"))
let nonce = parse("5", UInt128)

proc effectOf(j: string): Effect = effectFromJson(j)
proc callJson(signer = acct.accountId, nonces = @[nonce], instruction = nativeTransfer(parse("200", UInt128)),
              fee = some defaultFee(acct.accountId)): string =
  lezFrostCallEffect3(NativeTokenProgram, @[nativeShard(acct.accountId), nativeShard(to)], instruction,
                      signer, nonces, fee)

# ── 1. the effect, and what is signed ─────────────────────────────────────────
let e = effectOf(callJson())
doAssert e.schemaId == "muster.effect.lez-call.v2", e.schemaId
let want = LezMessage3(programAccount: NativeTokenProgram,
                       shards: @[nativeShard(acct.accountId), nativeShard(to)], nonces: @[nonce],
                       instruction: nativeTransfer(parse("200", UInt128)), fee: some defaultFee(acct.accountId))
doAssert d.frostMessages(e) == @[@(messageHash(want))], "the materialization is the v0.3 message hash"
doAssert d.signRefusal(e) == "", d.signRefusal(e)
let m1 = d.canonicalize(e)
doAssert m1.bytes == d.canonicalize(effectOf(callJson())).bytes, "deterministic"
doAssert toHex(messageHash(want)) in toHex(m1.bytes)
echo "1. lez-call v2: the materialization is the v0.3 message hash of exactly that call OK"

# ── 2. refusals before anyone signs ───────────────────────────────────────────
proc refused(j: string, why: string) =
  let r = d.signRefusal(effectOf(j))
  doAssert r.len > 0 and why in r, "wanted a refusal naming '" & why & "', got '" & r & "'"
refused(callJson(signer = other), "signer")
refused(callJson(nonces = @[nonce, nonce]), "nonce")
refused(callJson(instruction = @[]), "instruction")
refused(callJson(fee = none(LezFee)), "fee")
refused(callJson(fee = some defaultFee(other)), "fee")
echo "2. refused before signing: another signer, two nonces, no instruction, no fee, someone else's fee OK"

# ── 3. the manifest ───────────────────────────────────────────────────────────
let mf = d.manifest(e)
doAssert mf.touches.anyIt(it.target == "lez:local:" & toHex(NativeTokenProgram) and it.mode == tmRead)
doAssert mf.touches.anyIt(it.target == "lez:local:" & toHex(to) and it.mode == tmWrite)
echo "3. the manifest names the program and every row OK"

# ── 4. v1 is the v0.2.4 line, unchanged ───────────────────────────────────────
let program = hexToBytes("ccc4713e2b5ecdff37b0c67c295369effc04b7e8994eb11c3f410bb226b82e9b")
let v1 = effectOf(lezFrostCallEffect(program, @[acct.accountId, to], @[0'u32, 200, 0, 0, 0], acct.accountId, nonce))
doAssert v1.schemaId == "muster.effect.lez-call.v1"
doAssert d.frostMessages(v1) == @[@(messageHash(LezMessage(program: program, accounts: @[acct.accountId, to],
                                                             nonces: @[nonce], words: @[0'u32, 200, 0, 0, 0])))]
doAssert d.signRefusal(v1) == ""
echo "4. a v1 effect still hashes as v0.2.4's message OK"

# ── 5. only a call whose outcome muster can tell, and only one the account covers ──
proc call3(program = NativeTokenProgram, shards = @[nativeShard(acct.accountId), nativeShard(to)],
           instruction = nativeTransfer(parse("200", UInt128))): string =
  lezFrostCallEffect3(program, shards, instruction, acct.accountId, @[nonce], some defaultFee(acct.accountId))
refused(call3(program = other), "outcome")
refused(call3(shards = @[nativeShard(to), nativeShard(acct.accountId)]), "outcome")
refused(call3(shards = @[nativeShard(acct.accountId), nativeShard(to), nativeShard(other)]), "outcome")
refused(call3(shards = @[nativeShard(acct.accountId), LezShard(account: to, program: other)]), "outcome")
refused(call3(instruction = @[1'u8] & nativeTransfer(parse("200", UInt128))[1 .. ^1]), "outcome")
refused(call3(instruction = nativeTransfer(parse("200", UInt128))[0 .. ^2]), "outcome")
doAssert d.signRefusal(effectOf(call3())) == ""
# settle: the account's balance at the signed nonce must cover the amount and the fee cap
let fake = newFakeLezMultisig("lez:local", psLee02, newSeq[byte](32))
let stl = settlementFor(d, fake, Account(chain: "lez:local", form: afPublic, id: ""))
let at0 = effectOf(lezFrostCallEffect3(NativeTokenProgram, @[nativeShard(acct.accountId), nativeShard(to)],
                                       nativeTransfer(parse("200", UInt128)), acct.accountId,
                                       @[0.stuint(128)], some defaultFee(acct.accountId)))
let cap = defaultFee(acct.accountId).maxFee.truncate(uint64)
fake.fund(acct.accountId, cap + 199)
let short = stl.assemble(d, at0, @[])
doAssert not short.ok and short.error == "not-settleable" and "cover" in short.detail, short.error & " " & short.detail
fake.fund(acct.accountId, 1)
let covered = stl.assemble(d, at0, @[])
doAssert not covered.ok and covered.error == "insufficient-signatures", covered.error & " " & covered.detail
echo "5. refused before signing: any v0.3 call but a native transfer out of the account; at settle, a transfer ",
     "the account cannot cover with its fee cap OK"

echo "lez_frost_v030_test: a FROST group's LEZ call on v0.3, in the room — all OK"
