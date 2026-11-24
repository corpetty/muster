## No bytes a peer (or a chain, or an RPC) hands over may take the module down (exo-cd3,
## the 2026-11-22 audit P2-02). A binding event of 65 bytes made `decodeLink` read past its
## end; the IndexDefect escaped every `except CatchableError`, the FFI dispatch included,
## and the event stayed in the store, so every member crashed on every relaunch.
##
## Every decoder that reads outside input gets random bytes and every truncation of a few
## seeds; it may raise a CatchableError (a refusal) but never a Defect.

import std/[random, strutils, tables]
import ../src/crypto/binding
import ../src/crypto/join_request
import ../src/dcbor/dcbor
import ../src/bitcoin/psbt
import ../src/bitcoin/bech32
import ../src/lez/msig
import ../src/lez/multisig
import ../src/lez/quest
import ../src/lez/tx
import ../src/monero/address
import ../src/drivers/safe_rpc
import ../src/log/log
import ../src/coordination/intent_events

var defects = 0
template survives(label: string, body: untyped) =
  try:
    body
  except CatchableError:
    discard
  except Defect as fault:
    inc defects
    echo "DEFECT in ", label, ": ", fault.msg

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc feed(input: seq[byte]) =
  let s = cast[string](input)
  survives("decodeLink"): discard decodeLink(input)
  survives("decodeJoinRequest"): discard decodeJoinRequest(input)
  survives("dcbor.decode"): discard decode(input)
  survives("parsePsbt"): discard parsePsbt(input)
  survives("parsePsbtBase64"): discard parsePsbtBase64(s)
  survives("decodeSegwitAddress"): discard decodeSegwitAddress("bc", s)
  survives("msig.decodeProposal"): discard msig.decodeProposal(input)
  survives("msig.decodeInstruction"): discard decodeInstruction(input)
  survives("msig.decodePublicEnvelope"): discard decodePublicEnvelope(input)
  survives("msig.decodeSpend"): discard decodeSpend(input)
  survives("msig.decodeMsigConfig"): discard decodeMsigConfig(input)
  survives("msig.decodeMsigState"): discard decodeMsigState(input)
  survives("msig.decodeNote"): discard decodeNote(input)
  survives("msig.decodeRecipient"): discard decodeRecipient(input)
  survives("multisig.decodeState"): discard multisig.decodeState(input)
  survives("multisig.decodeProposal"): discard multisig.decodeProposal(input)
  survives("decodeQuestRecord"): discard decodeQuestRecord(input)
  survives("decodeQuestInstruction"): discard decodeQuestInstruction(input)
  survives("decodeLeeTxPublic"): discard decodeLeeTxPublic(input)
  survives("monero.decodeAddr"): discard decodeAddr(s)
  survives("decodeAddressArray"): discard decodeAddressArray("0x" & hexOf(input))
  survives("decodeModulesPage"): discard decodeModulesPage("0x" & hexOf(input))
  # the event the audit's crash rode in: a key binding's value, folded by every member
  survives("declineFold"):
    discard declineFold(@[Event(key: "intent/x/binding/0xab", value: hexOf(input)),
                          Event(key: "intent/x/decline/" & "ab".repeat(64), value: "1")])

# ── the audit's own repro: 64 bytes of identity and one more ────────────────────
var crashed = false
try: discard decodeLink(newSeq[byte](65))
except BindingError: discard
except Defect: crashed = true
doAssert not crashed, "a 65-byte link frame is a refusal, not a crash"
try: discard declineFold(@[Event(key: "intent/x/binding/0xab", value: "00".repeat(65))])
except Defect: crashed = true
doAssert not crashed, "declineFold survives a malformed binding"
echo "1. the audit's binding repro is refused, not a crash OK"

# ── every truncation of a few shaped seeds, then random bytes ──────────────────
var r = initRand(0x3b3)
var seeds: seq[seq[byte]] = @[newSeq[byte](0)]
for n in [1, 2, 3, 32, 64, 65, 66, 67, 140, 200]:
  var s = newSeq[byte](n)
  for i in 0 ..< n: s[i] = byte(r.rand(255))
  seeds.add s
var maxed = newSeq[byte](80)
for i in 0 ..< 80: maxed[i] = 0xFF     # every length field at its largest
seeds.add maxed
for sd in seeds:
  for cut in 0 .. sd.len: feed(sd[0 ..< cut])
for _ in 0 ..< 3000:
  var b = newSeq[byte](r.rand(300))
  for i in 0 ..< b.len: b[i] = byte(r.rand(255))
  feed(b)
doAssert defects == 0, $defects & " decoder(s) let a Defect escape"
echo "2. every wire decoder survives truncations and random bytes OK"

echo "wire_decoders_fuzz_test: all OK"
