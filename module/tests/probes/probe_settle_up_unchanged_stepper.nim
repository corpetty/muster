## derived-exo-a90.17 s6: what does not change — the private split is never netted: no share of
## it is covered and its zone gets no rate; a settle-up on one chain in one asset is byte for
## byte what it was, the same effect and the same signed bytes, and keeps every rule of
## derived-exo-a90.20 (exo-a90.17).
##
## STEPPER: state = one of 16 cases, chained case -> case+1.
##   0-11   golden vectors: twelve settle-ups in one asset — ETH and a 6-decimal token on
##          eip155:31337, BTC on regtest, four seeds each — computed ONCE on main at 0b19891,
##          before exo-a90.17 landed (a throwaway generator in a separate worktree, the same
##          construction as below), and frozen here as the sha256 of the effect JSON and of the
##          signed bytes. Each is rebuilt with today's code twice — its covers bare, as main
##          built them, and naming their own chain and asset, as openParts builds them now — and
##          both must reproduce both digests, and the driver must still accept it;
##   12     a settle-up across assets covering a share of the private split, with a rate for its
##          zone: the driver refuses it;
##   13     a rate for the private zone with no share of it covered: refused;
##   14     the private split's own driver refuses any settle-up, across assets or not;
##   15     in a room holding an agreed private split and agreed public ones, openPartsAll never
##          lists a private share, and a rate for the zone composes nothing ("no open share").
## The rest of derived-exo-a90.20's rules for a settle-up in one asset stay held by that spec,
## graded in the same run. Run by hand (no argv), it checks all 16 with doAssert.

import std/[json, strutils, sequtils]
import ../../src/hashing/sha256
import ../../src/intents/materialization
import ./settle_across_room
import ./oracle_emit

const N = 16
const At = 1_790_000_000'i64
const Golden = [
  ("ETH", 0, "c0e5762b75cd2540bf598802cfa97bc0dfa2ccdd6d510c2a1a6b6f29e930437f", "f2dff11fbdad5ec3b4cd587e1dc95ce68c92b4b0b147516d6572c96aacb12ffd"),
  ("ETH", 1, "67f4f01b45edca7d7fbd05fcbd05d29b42a70f462602d6f26b55f62482a7c427", "cca7cc85083d19e8960c089880c44bddae0013e05ca7185d25fa7ad871982258"),
  ("ETH", 2, "cfc141414b3b4f5362d490ae12f2b00aeeeb0534e2333c9b65b3c7bab8a8ef9d", "135815db3695b780a640172820e610c770a031a3a89be00efb44f62f898c1420"),
  ("ETH", 3, "2b2fe925bfe4dd9703c13bafaac86a32552a3839508daef4ff8da75d25bc38a4", "245b4a12101ff1a369055b04f5db309bb90aa4aa08df6532b807e87b1eaf6863"),
  ("TOKEN", 0, "724c67c461929cb0da8547d9be09ace31ba4846275eaafc9aa150cc8c1b52280", "325b5ca14303098004683eaf45ec7dcdcf024edb13d067a3d6c09e7f4c9ba7cd"),
  ("TOKEN", 1, "5e16de19875ee3b89b0a16555cf3a5be583763924b8e53801cc3f48fbf4d4026", "f712cb1b2be4a908c5730663f22dfa5b366dca4d5704637d7eec2780a148d8bb"),
  ("TOKEN", 2, "c9005f94c4025f117a1f50b5048d53752742720715a74ea7e35da9ad26f062f4", "c4d76f1f8c43bc2979cbb5f9f44c8d3a564a96c148674536be870a024a3c5bd8"),
  ("TOKEN", 3, "f548558cc4690970f7a500bb44fbd3ae0b883ee1475bb940ed56476f9ee86a1c", "71da615993d7f7ddf264c9d06ed998ef019e3ba50d448b33f719a51cda1e95a5"),
  ("BTC", 0, "4d39f0eb9c7e1cc419b2b7fceb5df72dddbe5f66fc263a0aede4316bd6b172fa", "2a0946fa98a9a76cf1573a0b7d0fdfe43081b88ac6eea417a214b6dc3588d6bb"),
  ("BTC", 1, "47ea3154cd231cdeaf2cc41e6f403c3e55e7d7897579804bd21cd90496f36dfb", "c1b8b629d28519625a020ec4abd3c8b6dd825959df7613c38f912a687e5ce71f"),
  ("BTC", 2, "dd1c16f6ff000b396d0b0faf35491d5c3a8a2f0a7b55769e043db5dc260ac25f", "1c4c03d4a06acb7ca1116e5c3cc1c9be883d5f4720e42680ee31fedae5e50eb0"),
  ("BTC", 3, "fa8d91000433f6d3e93fe3bcb9e6ac944baaa71ef5c8ca6e26b360fd82afaf18", "03f585c74b92496b52081d5ce76f294e7cd5607d69fba1ea11cf17f425dc39ad")]
let LezPayTo = "priv:" & repeat("ab", 32) & ":" & repeat("cd", 33)

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc digest(s: string): string = hexOf(sha256(s.toOpenArrayByte(0, s.high)))
proc digest(b: seq[byte]): string = hexOf(sha256(b))

proc goldenCase(k: int): bool =
  ## The same construction as the generator that ran on main.
  let (rail, seed, wantEffect, wantBytes) = Golden[k]
  let (chain, asset, family, base) =
    (if rail == "ETH": (EvmChain, "ETH", EvmSplitFamily, 1_000_000_000_000_000'u64)
     elif rail == "TOKEN": (EvmChain, Token, EvmSplitFamily, 1_000_000'u64)
     else: (BtcChain, "BTC", BtcSplitFamily, 20_000'u64))
  let drv = newSplitDriver(family, chain, roster)
  for named in [false, true]:
    var covers: seq[Cover]
    for i in 0 ..< 2 + seed mod 3:
      let d = (seed + i) mod 4
      let c = (d + 1 + (i mod 2)) mod 4
      var cv = Cover(intent: "0x" & repeat(toHex(seed * 16 + i + 1, 2).toLowerAscii(), 32), debtor: roster[d],
                     creditor: roster[c], amount: $(base + uint64(1000 * seed + 37 * i)),
                     payTo: payToOn(Members[c], chain))
      if named: (cv.chain = chain; cv.asset = asset)
      covers.add cv
    let effect = settleUpEffectJson(chain, asset, covers, netTransfers(covers), "golden " & rail & " " & $seed)
    if digest(effect) != wantEffect:
      stderr.writeLine "golden " & rail & " " & $seed & (if named: " (named covers)" else: "") & ": the effect changed"
      return false
    if drv.signRefusal(effectFromJson(effect)).len > 0: return false
    if digest(canonicalize(drv, effectFromJson(effect)).bytes) != wantBytes:
      stderr.writeLine "golden " & rail & " " & $seed & ": the signed bytes changed"
      return false
  true

proc correct(k: int): bool =
  if k < Golden.len: return goldenCase(k)
  let evmDrv = newSplitDriver(EvmSplitFamily, EvmChain, roster)
  let dinner = Cover(intent: "0x" & repeat("11", 32), debtor: carol, creditor: alice, amount: "300000",
                     payTo: evmAddrOf["alice"], chain: EvmChain, asset: "ETH")
  let hotel = Cover(intent: "0x" & repeat("22", 32), debtor: carol, creditor: bob, amount: "5000",
                    payTo: btcAddrOf("bob"), chain: BtcChain, asset: "BTC")
  let priv = Cover(intent: "0x" & repeat("33", 32), debtor: carol, creditor: dave, amount: "899999",
                   payTo: LezPayTo, chain: LezChain, asset: "LEZ")
  let btcRate = SettleRate(chain: BtcChain, asset: "BTC", rate: "214000000000", per: "1", source: "q", at: $At)
  let lezRate = SettleRate(chain: LezChain, asset: "LEZ", rate: "1", per: "1", source: "q", at: $At)
  let ts = @[NetTransfer(frm: carol, to: alice, payTo: evmAddrOf["alice"], amount: "300000"),
             NetTransfer(frm: carol, to: bob, payTo: evmAddrOf["bob"], amount: "1070000000000000"),
             NetTransfer(frm: carol, to: dave, payTo: evmAddrOf["dave"], amount: "899999")]
  proc refused(js: string): bool =
    try: evmDrv.signRefusal(effectFromJson(js)).len > 0
    except CatchableError: true
  # the honest base, without the private share: accepted, so a refusal below is the private split's
  if evmDrv.signRefusal(effectFromJson(settleUpEffectJson(EvmChain, "ETH", @[dinner, hotel], ts[0 .. 1], "base",
                                                           @[btcRate]))).len > 0: return false
  case k
  of 12: refused(settleUpEffectJson(EvmChain, "ETH", @[dinner, hotel, priv], ts, "with the private split",
                                    @[btcRate, lezRate]))
  of 13: refused(settleUpEffectJson(EvmChain, "ETH", @[dinner, hotel], ts[0 .. 1], "a rate for the zone",
                                    @[btcRate, lezRate]))
  of 14:
    let lezDrv = newSplitDriver(LezSplitFamily, LezChain, roster)
    let onZone = Cover(intent: priv.intent, debtor: carol, creditor: dave, amount: "899999", payTo: LezPayTo,
                       chain: LezChain, asset: "LEZ")
    let other = Cover(intent: "0x" & repeat("44", 32), debtor: bob, creditor: dave, amount: "899998", payTo: LezPayTo,
                      chain: LezChain, asset: "LEZ")
    let plain = settleUpEffectJson(LezChain, "LEZ", @[onZone, other], netTransfers(@[onZone, other]), "on the zone")
    let across = settleUpEffectJson(LezChain, "LEZ", @[onZone, other, hotel],
                                    netTransfers(@[onZone, other, hotel], @[btcRate], LezChain, "LEZ"), "across",
                                    @[btcRate])
    lezDrv.signRefusal(effectFromJson(plain)).len > 0 and lezDrv.signRefusal(effectFromJson(across)).len > 0
  else:
    var r = newRoom4("/muster/1/probe-unchanged-" & $k & "/proto")
    discard r.splitAgreed(EvmChain, "ETH", "alice", @["bob", "carol"], "900000", "dinner")
    discard r.splitAgreed(BtcChain, "BTC", "bob", @["carol"], "10000", "hotel")
    let lezEffect = splitEffectJson(LezChain, "LEZ", "900000", dave, LezPayTo,
                                    evenShares("900000", dave, @[bob, carol], distinctAmounts = true), "private")
    let lezId = r.proposeAs("dave", LezPolicy, lezEffect, LezChain)
    if not lezId.startsWith("0x"): return false
    r.sync()
    discard r.agreeAs("bob", lezId)
    discard r.agreeAs("carol", lezId)
    if r.stateIn(lezId) != "executable": return false     # agreed: it would be open, were it public
    let open = openPartsAll(r.alice.roomEvents(), acrossFor, Now)
    if open.len != 3 or open.anyIt(it.intent == lezId or it.chain == LezChain): return false
    let composed = settleUpAcross(r.alice.roomEvents(), acrossFor, EvmChain, "ETH",
                                  @[SettleRate(chain: BtcChain, asset: "BTC", rate: "7", per: "3", source: "q", at: $At),
                                    lezRate], "with the zone", Now)
    composed.why.startsWith("no open share") and composed.effectJson.len == 0

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N: doAssert correct(k), "case " & $k & " judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
