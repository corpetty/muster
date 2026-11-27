## lez-msig's defaults (exo-c0c, exo-a99, exo-5ed), with no chain:
##   1. private by default: an open that does not say private: false is private, and needs the
##      zone line's prover; without it the open is refused, naming the module to install, and
##      never made public. private: false opens a public one without asking the zone;
##   2. every time a client picks reaches a public validity window, so each is a whole minute:
##      an expiry rounds down (never longer than asked, still in the future), a Queue's at_ms
##      (the latest it may land) rounds up, so its ETA stays pessimistic, and ExecuteQueued's
##      (the earliest) is the minute it is sent in, at or after the ETA;
##   3. a proposal and a spend made in the room carry a whole-minute expiry;
##   4. settlement's Queue and ExecuteQueued carry whole-minute at_ms, in that order;
##   5. the live e2e's spend waits out a period too close to its end (exo-5ed).
## Needs the secp closure + libsodium.

import std/[json, options, sequtils, strutils]
import stint
import ../src/crypto/keystore
import ../src/drivers/driver
import ../src/drivers/lez_msig
import ../src/coordination/intent_events
import ../src/coordination/msig_room
import ../src/lez/msig
import ../src/bitcoin/tx                 # hexToBytes
import ../src/intents/materialization
import ../src/wallet/types
import ../src/wallet/msig_prover
import ../src/wallet/lez_msig_chain
import ../src/settlement/settlement
import ./probes/msig_period

const Minute = 60_000'u64

# ── 1. private by default ─────────────────────────────────────────────────────
block:
  proc line(l: string): proc(): string = (proc(): string = l)
  let unreadable = proc(): string = raise newException(IOError, "connection refused")
  let none = proc(l: string): bool = false
  let both = proc(l: string): bool = true
  var p = msigPostureOf(%*{"threshold": 2}, line("v0.3"), both)
  doAssert p.ok and p.private, "no private key: private"
  p = msigPostureOf(%*{"threshold": 2}, line("v0.3"), none)
  doAssert not p.ok and p.error == "no-prover" and p.install == "lez_msig_module", $p
  doAssert "private: false" in p.detail, "it says how to open a public one: " & p.detail
  p = msigPostureOf(%*{"threshold": 2}, line("v0.4"), none)
  doAssert not p.ok and p.install == "lez_msig_v04_module", "v0.4 names its own prover"
  p = msigPostureOf(%*{"threshold": 2}, line("v0.4"), proc(l: string): bool = l == "v0.3")
  doAssert not p.ok and p.install == "lez_msig_v04_module", "the v0.3 prover does not serve a v0.4 zone"
  p = msigPostureOf(%*{"private": true}, line("v0.3"), none)
  doAssert not p.ok and p.error == "no-prover" and "private: false" notin p.detail,
    "asked for private: refused, with no offer of public"
  p = msigPostureOf(%*{"private": false}, unreadable, none)
  doAssert p.ok and not p.private, "private: false is public, and the zone is not asked"
  p = msigPostureOf(%*{}, unreadable, both)
  doAssert not p.ok and p.error == "refused" and "connection refused" in p.detail and "private: false" in p.detail
  p = msigPostureOf(%*{"private": "yes"}, line("v0.3"), both)
  doAssert not p.ok and p.error == "bad-spec"
  echo "1. private by default; no prover: refused, naming the module, never made public OK"

# ── 2. the times, to the minute ───────────────────────────────────────────────
block:
  for now in [1_790_000_000_000'u64, 1_790_000_000_001'u64, 1_790_000_059_999'u64, 1_790_000_040_000'u64]:
    for ttl in [Minute, Minute + 1, 24'u64 * 3_600_000, 7'u64 * 24 * 3_600_000]:
      let e = msigExpiryMs(now, ttl)
      doAssert e mod Minute == 0 and e > now and e <= now + ttl, "expiry " & $now & " + " & $ttl & " → " & $e
    let q = queueAtMs(now, 120_000)
    doAssert q mod Minute == 0 and q >= now + 120_000 and q < now + 120_000 + Minute, "Queue's at_ms"
    let x = executeQueuedAtMs(now)
    doAssert x mod Minute == 0 and x <= now and now - x < Minute, "ExecuteQueued's at_ms"
  var raised = false
  try: discard msigExpiryMs(1_790_000_000_000'u64, 59_999)
  except ValueError: raised = true
  doAssert raised, "an expiry under a minute away is refused"
  # ExecuteQueued is sent once the minute it is sent in is at or after the ETA
  let m0 = 1_790_000_040_000'u64                   # a whole minute
  doAssert m0 mod Minute == 0
  let eta = m0 + 90_000                            # 30 s into a minute
  doAssert not executeQueuedReady(eta, eta) and not executeQueuedReady(m0 + 119_999, eta)
  doAssert executeQueuedReady(m0 + 120_000, eta) and executeQueuedAtMs(m0 + 120_000) >= eta
  doAssert executeQueuedReady(m0 + 120_000, m0 + 120_000), "an ETA on the minute"
  echo "2. expiry down, Queue's at_ms up, ExecuteQueued's the minute it is sent in, after the ETA OK"

# ── the multisig, as the driver test builds it ────────────────────────────────
proc fill(x: byte): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 32: result[i] = x

const Chain = "lez:local"
let program = fill(0x11)
let createKey = fill(0x22)
let zone = fill(0x2e)
proc keystore(seed: byte): Keystore =
  var a, b: array[32, byte]
  for i in 0 ..< 32: (a[i] = seed; b[i] = seed xor 0x5a)
  newInMemoryKeystore(a, b)
let ks = @[keystore(1), keystore(2), keystore(3)]
let label = msigLabel(createKey)
let keys = ks.mapIt(it.lezMemberKey(label))
let a = multisigPublic(program, createKey)
let lockMs = 90_000'u64                            # not a whole minute: the ETA is not one either
let config = MsigConfig(members: keys.mapIt(MsigMember(key: it, roles: RoleAll, weight: 1)), threshold: 2,
                        timelockMs: lockMs, openExecution: true, actions: ActAll,
                        limits: @[MsigLimit(id: 1, signers: @[keys[1]], threshold: 1, amount: 500.u128, periodMs: 3_600_000)])
let acct = LezMsigAccount(chain: Chain, program: program, createKey: createKey, zone: zone, address: a,
                          accountId: Chain & ":" & hexOf(a), epoch: 0, config: config)
let drv = newLezMsigDriver(acct)
var st = MsigState(version: 1, zone: zone, createKey: createKey, epoch: 0, config: config,
                   consumed: newSeq[byte](32))

# ── 3. a proposal and a spend from the room ───────────────────────────────────
let now0 = 1_790_000_037_123'u64
let pay = MsigAction(kind: akTransfer, to: fill(0x0e), amount: 100.u128)
let p = newMsigProposal(@[], ks[0], drv, st, pay, msigExpiryMs(now0, 7'u64 * 24 * 3_600_000))
doAssert p.expiresMs mod Minute == 0 and p.expiresMs > now0 and p.expiresMs <= now0 + 7'u64 * 24 * 3_600_000
doAssert newMsigProposal(@[], ks[0], drv, st, pay, now0 + 3_600_000).expiresMs mod Minute == 0,
  "the constructor rounds whatever it is handed"
let sp = newMsigSpend(@[], drv, st, 1, fill(0x0e), 100.u128, now0 + 86_400_000)
doAssert sp.expiresMs mod Minute == 0 and sp.expiresMs <= now0 + 86_400_000
echo "3. a proposal's and a spend's expiry are whole minutes OK"

# ── 4. settlement's Queue and ExecuteQueued ───────────────────────────────────
type FakeChain = ref object of MsigChain
  state: MsigState
  now: uint64
method readMsig(c: FakeChain, account: seq[byte]): MsigRead =
  MsigRead(found: account == a, state: c.state, balance: 5000.u128, height: 1)
method nowMs(c: FakeChain): uint64 = c.now

proc approval(i: int, p: MsigProposal): SettleContribution =
  var m: array[32, byte]
  let am = approveMsg(proposalId(p))
  for j in 0 ..< 32: m[j] = am[j]
  (contributor: ContributorPrefix & hexOf(keys[i]), bytes: contributionOf(keys[i], ks[i].lezMemberSign(label, m)))

block:
  let chain = FakeChain(chain: Chain, program: program, state: st, now: now0)
  let effect = effectFromJson(lezMsigEffect(p))
  let contributions = @[approval(0, p), approval(1, p)]
  let s = LezMsigSettlement(settlementFor(drv, chain, Account(chain: Chain, form: afPublic, id: "")))
  let q = s.assemble(drv, effect, contributions)
  doAssert q.ok, q.error & ": " & q.detail
  let qins = parseJson(q.tx.payload)
  doAssert qins["msig"].getStr() == $ikQueue
  let qi = decodeInstruction(hexToBytes(qins["op"].getStr()))
  doAssert qi.kind == ikQueue and qi.atMs mod Minute == 0, "Queue's at_ms is a whole minute: " & $qi.atMs
  doAssert qi.atMs >= now0 + 120_000, "and no earlier than now plus the slack: the ETA is pessimistic"
  # the program queues it with eta = at_ms + the lock (core rules.rs)
  let eta = qi.atMs + lockMs
  doAssert eta mod Minute != 0, "this lock makes an ETA off the minute"
  chain.state.queue = @[MsigQueued(nonce: p.nonce, proposalId: proposalId(p), etaMs: eta, expiresMs: p.expiresMs)]
  chain.now = eta + 1
  let early = s.assemble(drv, effect, contributions)
  doAssert not early.ok and "time lock ends" in early.detail, "past the ETA, but not a whole minute past it: " & early.detail
  chain.now = ceilMinute(eta) + 7_000
  let x = s.assemble(drv, effect, contributions)
  doAssert x.ok, x.detail
  let xi = decodeInstruction(hexToBytes(parseJson(x.tx.payload)["op"].getStr()))
  doAssert xi.kind == ikExecuteQueued and xi.atMs mod Minute == 0 and xi.atMs >= eta and xi.atMs <= chain.now,
    "ExecuteQueued's at_ms: a whole minute, at or after the ETA, no later than it is sent"
  doAssert xi.atMs < p.expiresMs
  # a lock that leaves no whole minute between the ETA and the expiry is refused before sending
  var tight = st
  tight.config.timelockMs = p.expiresMs - queueAtMs(now0, 120_000) - 1
  let s2 = LezMsigSettlement(settlementFor(drv, FakeChain(chain: Chain, program: program, state: tight, now: now0),
                                           Account(chain: Chain, form: afPublic, id: "")))
  let r2 = s2.assemble(drv, effect, contributions)
  doAssert not r2.ok and "time lock" in r2.detail, r2.detail
echo "4. settlement: Queue's at_ms rounds up, ExecuteQueued's is a whole minute after the ETA OK"

# ── 5. the e2e's spend waits out a period's end (exo-5ed) ─────────────────────
block:
  let hour = 3_600_000'u64
  let need = SpendMarginMs + 180_000
  doAssert spendWaitMs(10 * hour, hour, need) == 0, "a period just begun"
  doAssert spendWaitMs(10 * hour + hour - need, hour, need) == 0, "exactly enough left"
  let late = 10 * hour + hour - need + 1
  let w = spendWaitMs(late, hour, need)
  doAssert w > 0 and (late + w) div hour == 11 and hour - (late + w) mod hour >= need,
    "too close to the end: wait into the next period, with the step's time left"
  # the CI failure: settlement 30 s before the hour's end
  let ci = 10 * hour + hour - 30_000
  doAssert (ci + spendWaitMs(ci, hour, need)) div hour == 11
echo "5. the e2e's spend never starts within its step of a period's end OK"

echo "lez_msig_defaults_test: all passed"
