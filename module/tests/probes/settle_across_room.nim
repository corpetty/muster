## A shared fixture for derived-exo-a90.17's probes (a settle-up across assets and chains,
## exo-a90.17): split_room's room of four, with the rails a cross-asset settle-up nets —
## Ethereum on eip155:31337 (ETH and a 6-decimal token), a second Ethereum chain
## (eip155:1), and Bitcoin regtest — and the probe's OWN arithmetic for a conversion (a
## 512-bit product, never the module's 256-bit one). Not a probe itself (no `probe_` prefix).
## Build: see live_room.nim.

import std/[strutils, tables, sequtils]
import stint
import ../../src/bitcoin/script
import ../../src/coordination/intent_events
import ../../src/coordination/settle_up
import ../../src/coordination/parts
import ./split_room
export split_room, settle_up, parts, intent_events, stint, tables

const BtcChain* = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const BtcPolicy* = "btc-split@" & BtcChain
const MainChain* = "eip155:1"                          ## another Ethereum chain: two chains, not one
const MainPolicy* = "evm-split@" & MainChain
const Token* = "erc20:0x5fbdb2315678afecb367f032d93f642f64180aa3"   ## a 6-decimal token on eip155:31337
const Members* = ["alice", "bob", "carol", "dave"]

let acrossFor*: DriverFor = proc(policy: string): Driver =
  if policy == BtcPolicy: newSplitDriver(BtcSplitFamily, BtcChain, roster)
  elif policy == MainPolicy: newSplitDriver(EvmSplitFamily, MainChain, roster)
  else: splitFor(policy)

proc ksOf*(who: string): Keystore =
  case who
  of "alice": Keystore(aliceKs)
  of "bob": Keystore(bobKs)
  of "carol": Keystore(carolKs)
  else: Keystore(daveKs)

let evmAddrOf* = {"alice": AlicePayTo, "bob": "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
                  "carol": "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
                  "dave": "0x90f79bf6eb2c4f870365e785982e1f101e93b906"}.toTable   ## each member's own key's address

proc btcAddrOf*(who: string): string = p2wpkhAddress("bcrt", ksOf(who).btcPubKey())
  ## each member's own key's regtest address — what their client holds on Bitcoin

proc nameOf*(identity: string): string =
  for m in Members:
    if identityOf(m) == identity: return m
  ""

proc policyOf*(chain: string): string =
  if chain == BtcChain: BtcPolicy elif chain == MainChain: MainPolicy else: EvmPolicy

proc payToOn*(who, chain: string): string =
  if chain == BtcChain: btcAddrOf(who) else: evmAddrOf[who]

proc proposeAs*(r: var Room4, who, policy, effect, account: string,
                reads: seq[tuple[field, source: string]] = @[]): string =
  inc r.seqNo
  let (s, ks) = r.sessionOf(who)
  liveProposeIntent(s, ks, acrossFor, policy, effect, int64(Now), r.seqNo, account = account, ttlSec = Ttl,
                    reads = reads)

proc agreeAs*(r: Room4, who, id: string): string =
  let (s, ks) = r.sessionOf(who)
  liveContribute(s, ks, acrossFor, id, "", "", LinkContext(account: "probe", slot: "0", expiry: Now + 86_400), Now)

proc stateIn*(r: Room4, id: string): string =
  r.sync()
  intentState(r.alice.roomEvents(), acrossFor, id)

proc splitAgreed*(r: var Room4, chain, asset, creditor: string, debtors: seq[string], total, memo: string,
                  payTo = ""): string =
  ## A split its creditor proposes (agreeing by proposing) and every debtor agrees to.
  let pt = (if payTo.len > 0: payTo else: payToOn(creditor, chain))
  let effect = splitEffectJson(chain, asset, total, identityOf(creditor), pt,
                               evenShares(total, identityOf(creditor), debtors.mapIt(identityOf(it))), memo)
  result = r.proposeAs(creditor, policyOf(chain), effect, chain & ":" & pt)
  doAssert result.startsWith("0x"), memo & ": " & result
  r.sync()
  for d in debtors: discard r.agreeAs(d, result)
  r.sync()

proc shareAddress*(r: Room4, who, asset, address: string, chain = "", seqNo = 1) =
  ## An author-signed address-share card, as the room's "Share an address" posts it — at
  ## Now + seqNo seconds, so a later share is later.
  var body = "{\"kind\":\"address-share\",\"asset\":\"" & asset & "\",\"address\":\"" & address & "\",\"form\":1"
  if chain.len > 0: body.add ",\"chain\":\"" & chain & "\""
  body.add "}"
  let (s, ks) = r.sessionOf(who)
  s.publishAuthored(ks, newMessageEvent(identityOf(who), int64(Now) + seqNo, body, uint64(seqNo))[1])
  r.sync()

# ── the probe's own arithmetic ─────────────────────────────────────────────────────
type U512* = StUint[512]

proc big*(s: string): tuple[ok: bool, v: U512] =
  ## Digits only, no sign, no point — or not ok. Any length up to 512 bits.
  if s.len == 0 or s.len > 150 or not s.allIt(it in '0' .. '9'): return (false, 0.stuint(512))
  var v = 0.stuint(512)
  for ch in s: v = v * 10.stuint(512) + stuint(ord(ch) - ord('0'), 512)
  (true, v)

proc pow10*(n: int): U512 =
  result = 1.stuint(512)
  for _ in 0 ..< n: result = result * 10.stuint(512)

let Max256* = (1.stuint(512) shl 256) - 1.stuint(512)

proc decimalUnits*(s: string, decimals: int): tuple[ok: bool, v: U512] =
  ## The probe's own reading of a typed decimal: digits and at most one point, at most
  ## `decimals` fraction digits, times 10^decimals — or not ok.
  let parts = s.split('.')
  if s.len == 0 or parts.len > 2: return (false, 0.stuint(512))
  for p in parts:
    if p.len == 0 or not p.allIt(it in '0' .. '9'): return (false, 0.stuint(512))
  let frac = (if parts.len == 2: parts[1] else: "")
  if frac.len > decimals: return (false, 0.stuint(512))
  big(parts[0] & frac & repeat('0', decimals - frac.len))

proc ownConversion*(amount, rate, per: string): tuple[ok: bool, v: U512, why: string] =
  ## amount × rate ÷ per, rounded down, by the probe's own 512-bit arithmetic: refused when
  ## the product does not fit 256 bits (the module's own width) or the result is zero.
  let (a, x, p) = (big(amount), big(rate), big(per))
  if not (a.ok and x.ok and p.ok) or p.v == 0.stuint(512): return (false, 0.stuint(512), "malformed")
  let prod = a.v * x.v
  if prod > Max256: return (false, 0.stuint(512), "overflows")
  let q = prod div p.v
  if q == 0.stuint(512): return (false, 0.stuint(512), "nothing")
  (true, q, "")
