## A private payee on LEZ v0.4 in Nim (exo-ea3; src/lez/msig.nim), held to
## tests/vectors/lez-msig/v04-recipients.json from LEZ's own crates
## (programs/lez-msig/lez04/host/src/bin/msig_recipient_vectors04.rs):
##   1. a recipient decodes from its borsh and derives the account id and address LEZ derives,
##      plain and blinded;
##   2. a padded, short, or PDA-kind recipient is refused;
##   3. the driver: a private multisig's payment to a private payee carries its recipient in the
##      effect and is approvable only when that recipient derives the address the proposal pays;
##      a mismatch, a non-transfer, or a public multisig is refused, and its approval matches no
##      signature (canonicalize's sentinel); the card says the payee is private.

import std/[json, os, options, sequtils, strutils]
import stint
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/lez_msig
import ../src/coordination/intent_events
import ../src/coordination/effect_summary
import ../src/lez/msig

proc hb(s: string): seq[byte] =
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))

var fails = 0
template check(cond: bool, what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc fails

let v = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-msig" / "v04-recipients.json"))["recipients"]
echo "1. LEZ's addresses"
for (i, row) in [(0, "plain"), (1, "blinded")]:
  let r = decodeRecipient(hb(v[i]["recipient"].getStr()))
  check(hexOf(recipientAccountId(r)) == v[i]["accountId"].getStr(), row & ": the account id")
  check(hexOf(recipientAddress(r)) == v[i]["address"].getStr(), row & ": the address")
check(decodeRecipient(hb(v[1]["recipient"].getStr())).opening.isSome, "the blinded one carries its opening")

echo "2. refusals"
proc refused(b: seq[byte]): bool =
  try: discard decodeRecipient(b); false
  except MsigDecodeError: true
let plain = hb(v[0]["recipient"].getStr())
check(refused(plain & @[0'u8]), "padded")
check(refused(plain[0 ..< plain.len - 1]), "short")
var pda = plain
pda[32 + 4 + ViewingKeyLen] = 1
check(refused(pda), "a PDA kind")

echo "3. the driver"
proc fill(x: byte): seq[byte] = (result = newSeq[byte](32); for i in 0 ..< 32: result[i] = x)
let a = fill(0x99)
proc acct(private: bool): LezMsigAccount =
  LezMsigAccount(chain: "lez:local", program: fill(0x11), createKey: fill(0x22), zone: fill(0x2e), address: a,
                 accountId: "lez:local:" & hexOf(a), epoch: 0, private: private,
                 config: MsigConfig(members: @[MsigMember(key: fill(1), roles: RoleAll, weight: 1)], threshold: 1,
                                    openExecution: true, actions: ActAll))
proc pay(to: seq[byte], kind = akTransfer): MsigProposal =
  let action = (if kind == akTransfer: MsigAction(kind: akTransfer, to: to, amount: 7_000_000.u128)
                else: MsigAction(kind: akCancel, nonces: @[1'u64]))
  MsigProposal(multisig: a, zone: fill(0x2e), epoch: 0, nonce: 0, action: action,
               expiresMs: 9_000_000_000_000'u64, proposer: fill(1))
let rec = hb(v[1]["recipient"].getStr())
let paidTo = recipientAddress(decodeRecipient(rec))
let priv = newLezMsigDriver(acct(true))
let good = effectFromJson(lezMsigEffect(pay(paidTo), rec))
check(payeeOf(good) == rec, "the effect carries the recipient")
check(priv.signRefusal(good) == "", "a recipient that derives the paid address is approvable")
check(decode(canonicalize(priv, good).bytes).arr.len == 3, "and canonicalizes to the proposal id")
let wrong = effectFromJson(lezMsigEffect(pay(fill(0x0e)), rec))
check("does not derive" in priv.signRefusal(wrong), "a recipient for another address is refused")
check(decode(canonicalize(priv, wrong).bytes).arr.len == 2, "and canonicalizes to a sentinel")
check("for a transfer" in priv.signRefusal(effectFromJson(lezMsigEffect(pay(paidTo, akCancel), rec))), "only a transfer has a payee")
check("private multisig" in newLezMsigDriver(acct(false)).signRefusal(good), "a public multisig cannot seal a payment")
check("a private payee" in effectSummary(lezMsigEffect(pay(paidTo), rec)).text, "the card names a private payee")
check("private payee" notin effectSummary(lezMsigEffect(pay(paidTo))).text, "and only then")
check(payeeOf(effectFromJson(lezMsigEffect(pay(paidTo)))).len == 0 and
      priv.signRefusal(effectFromJson(lezMsigEffect(pay(paidTo)))) == "", "a payment without a payee is unchanged")

if fails > 0:
  echo fails, " failed"
  quit 1
echo "lez_msig_recipient_test: all passed"
