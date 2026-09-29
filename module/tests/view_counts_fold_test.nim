## exo-b96 — every surface counts what the fold counts.
##
## A contribution event is keyed intent/<id>/sig/<who>/<round>, and any epoch-key holder
## can publish one. The fold (reduceIntents) counts a contribution only when the intent's
## driver verifies it; the surfaces read approvalGrades, which checked attribution alone
## (signedByNamed — true whenever the driver cannot NAME a signer, which is exactly what a
## driver says of an invalid contribution) and graded the rest "unattested". So a
## non-member's signature, a malformed one, a vote for another pointer, or a FROST payload
## replayed into the wrong round showed on the card as an approval the fold never counted —
## and in the activity feed ("Approved by …"), the intent's provenance and the room-wide
## log provenance. Invariant 9: what the client says about a member is only what that
## member disclosed; a view that claims an approval the decision does not contain says more.
##
## The oracle is the fold itself, never a re-implementation of it: the contributions are fed
## to reduceIntents one at a time, in the order it processes them, and a (who, round) is
## counted iff folding it in raised the number the fold accepted. Each surface
## must name exactly that set, for every driver family with its own verify rule — a room
## threshold, a Safe, the room FROST scaffold, a real two-round FROST (btc.frost-bip445,
## whose contributions carry their round), the vote-locus LEZ receipt, and the split (whose
## threshold is the parties its effect names — each debtor and, since exo-770, the creditor —
## and only a named party's room key agrees).
##
## Needs the secp closure + stint + libsodium (tests/README.md; run-suite.sh supplies them).

import std/[json, sets, sequtils, strutils, tables, algorithm]
import ../src/log/log
import ../src/hashing/sha256
import ../src/intents/materialization
import ../src/intents/provenance
import ../src/drivers/[driver, threshold, frost, safe, frost_group, btc_frost, lez_multisig, split]
import ../src/crypto/[curve25519, secp256k1, keystore]
import ../src/frost/chilldkg
import ../src/bitcoin/tx
import ../src/lez/multisig
import ../src/coordination/accounts
import ../src/coordination/intents

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc keyOf(e: Event, id: string): string =
  ## "<who>/<round>" for a contribution to `id`, "" for anything else.
  let p = e.key.split('/')
  if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
    return p[3] & "/" & (if p.len >= 5: p[4] else: "1")
  ""

proc foldAccepted(events: seq[Event], dfor: DriverFor, id: string): int =
  ## How many contributions the fold accepted toward the threshold, across its rounds.
  let it = reduceIntents(events, dfor)[id]
  (it.collection.round - 1) * it.collection.descriptor.threshold + it.collection.acceptedThisRound

proc foldOrder(events: seq[Event], id: string): seq[Event] =
  ## The contributions to `id` in the order reduceIntents folds them: by key round, then
  ## canonical order within a round.
  var xs: seq[(int, int, Event)]
  for i, e in canonicalOrder(events):
    let k = keyOf(e, id)
    if k.len > 0: xs.add ((try: parseInt(k.rsplit('/', 1)[1]) except CatchableError: 1), i, e)
  xs.sort(proc (a, b: (int, int, Event)): int = (if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1], b[1])))
  for x in xs: result.add x[2]

proc foldCounted(events: seq[Event], dfor: DriverFor, id: string): HashSet[string] =
  ## The (who, round) keys the fold counted: fed one at a time in its own order, each one
  ## that raised what it accepted. exo-9fb: removing one at a time instead let a later
  ## contribution take the freed place (a round-1 payload keyed round 2, counted toward a
  ## short round 1, exo-e42), so the verdict hung on the random order of FROST's events.
  var fed = events.filterIt(keyOf(it, id).len == 0)
  var total = foldAccepted(fed, dfor, id)
  for e in foldOrder(events, id):
    fed.add e
    let t = foldAccepted(fed, dfor, id)
    if t > total: result.incl keyOf(e, id)
    total = t

proc whoOf(keys: HashSet[string]): HashSet[string] =
  for k in keys: result.incl k.rsplit('/', 1)[0]

proc check(label: string, events: seq[Event], dfor: DriverFor, id: string,
           wantApprovals, wantRound: int) =
  let counted = foldCounted(events, dfor, id)
  let who = whoOf(counted)
  let it = reduceIntents(events, dfor)[id]
  doAssert who.len == wantApprovals and it.collection.acceptedThisRound == wantRound,
    label & ": the scenario is not what it claims (fold counted " & $counted & ")"

  var graded: HashSet[string]
  for g in approvalGrades(events, dfor, id):
    if g.grade != agRejected: graded.incl g.who & "/" & $g.round
  doAssert graded == counted, label & ": approvalGrades " & $graded & " but the fold counted " & $counted

  var view: IntentView
  for v in reduceIntentViews(events, dfor):
    if v.id == id: view = v
  doAssert view.approvals == who.len,
    label & ": the card says " & $view.approvals & " approved, the fold counted " & $who.len
  doAssert view.roundApprovals == it.collection.acceptedThisRound,
    label & ": the card says " & $view.roundApprovals & " this round, the fold " & $it.collection.acceptedThisRound
  doAssert view.committed + view.unattested == counted.len, label & ": grade totals"

  var feed: HashSet[string]
  for a in reduceActivity(events, dfor):
    if a.kind == "approve" and a.intentId == id: feed.incl a.account
  doAssert feed == who, label & ": the activity feed says approved by " & $feed & ", the fold " & $who

  var prov: HashSet[string]
  for p in intentProvenance(events, dfor, id):
    if p.cls == icContribution: prov.incl p.account
  doAssert prov == who, label & ": intentProvenance names " & $prov & ", the fold " & $who

  var logp: HashSet[string]
  for p in logProvenance(events, dfor):
    if p.kind == "sig" and p.intentId == id: logp.incl p.account
  doAssert logp == who, label & ": logProvenance names " & $logp & ", the fold " & $who

  # inv 4: the same verdict from the same SET, whatever order it arrived in
  var shuffled = events.reversed()
  shuffled.add events[^1]
  doAssert foldCounted(shuffled, dfor, id) == counted
  var graded2: HashSet[string]
  for g in approvalGrades(shuffled, dfor, id):
    if g.grade != agRejected: graded2.incl g.who & "/" & $g.round
  doAssert graded2 == counted, label & ": reordered"

let a = encFromSeed(seed(1))
let b = encFromSeed(seed(2))
let c = encFromSeed(seed(3))
let mallory = encFromSeed(seed(9))            # holds the epoch key; on no roster

# ── 1. a room threshold, k=2 of {a, b} ────────────────────────────────────────────
block:
  let thr = newThresholdDriver(@[a.identity().ed, b.identity().ed], k = 2)
  let thrFor: DriverFor = proc(kind: string): Driver = thr
  const stmtJson = """{"effect":"statement","text":"we agree"}"""
  let id = intentIdFor(stmtJson, "threshold")
  let m = canonicalize(thr, effectFromJson(stmtJson))
  let sigA = hx(edSign(a, m.bytes))
  let sigB = hx(edSign(b, m.bytes))
  let sigM = hx(edSign(mallory, m.bytes))
  let nameA = contributorOf(thr, stmtJson, sigA)
  let nameB = contributorOf(thr, stmtJson, sigB)
  let nameM = "ed:" & hx(mallory.identity().ed)
  let prop = @[policyDeclEvent(id, "threshold"), proposeEvent(id, stmtJson)]

  check("threshold: a non-member's signature", prop & @[contributeEvent(id, nameA, sigA),
        contributeEvent(id, nameM, sigM)], thrFor, id, wantApprovals = 1, wantRound = 1)
  check("threshold: a malformed signature under b's name", prop & @[contributeEvent(id, nameA, sigA),
        contributeEvent(id, nameB, "00".repeat(64))], thrFor, id, 1, 1)
  check("threshold: only the non-member", prop & @[contributeEvent(id, nameM, sigM)], thrFor, id, 0, 0)
  check("threshold: a and b complete it; mallory still isn't counted", prop & @[contributeEvent(id, nameA, sigA),
        contributeEvent(id, nameM, sigM), contributeEvent(id, nameB, sigB)], thrFor, id, 2, 2)
  echo "1. threshold: a non-member's or malformed signature is on no surface OK"

# ── 2. a Safe, 2-of-3 owners ──────────────────────────────────────────────────────
block:
  var keys: seq[array[32, byte]]
  var owners: seq[Address]
  for k in 1 .. 3:
    var sk: array[32, byte]; sk[31] = byte(k)
    keys.add sk; owners.add addressOf(sk)
  var outsider: array[32, byte]; outsider[31] = 9
  var safeAddr: Address
  for i in 0 ..< 20: safeAddr[i] = byte(0x10 + i)
  let sd = newSafeDriver(chainId = 31337, safe = safeAddr, owners = owners, threshold = 2)
  let safeFor: DriverFor = proc(kind: string): Driver = sd
  const payJson = """{"to":"0x00112233445566778899aabbccddeeff00112233","value":1000,"nonce":0}"""
  let id = intentIdFor(payJson)
  let pm = canonicalize(sd, effectFromJson(payJson))
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = pm.bytes[i]
  let s0 = hx(signRecoverable(h, keys[0]))
  let n0 = contributorOf(sd, payJson, s0)
  let n1 = contributorOf(sd, payJson, hx(signRecoverable(h, keys[1])))
  let sOut = hx(signRecoverable(h, outsider))
  let nOut = "0x" & hx(addressOf(outsider))
  let base = @[proposeEvent(id, payJson)]
  check("Safe: a non-owner's signature", base & @[contributeEvent(id, n0, s0), contributeEvent(id, nOut, sOut)],
        safeFor, id, 1, 1)
  check("Safe: a malformed signature under an owner's name", base & @[contributeEvent(id, n0, s0),
        contributeEvent(id, n1, "11".repeat(64))], safeFor, id, 1, 1)
  echo "2. Safe: a non-owner's or malformed signature is on no surface OK"

# ── 3. the room FROST scaffold: 2 rounds, k=2 of {a, b, c} ───────────────────────
block:
  let fr = newFrostDriver(@[a.identity().ed, b.identity().ed, c.identity().ed], k = 2)
  let frFor: DriverFor = proc(kind: string): Driver = fr
  const stmtJson = """{"effect":"statement","text":"frost"}"""
  let id = intentIdFor(stmtJson, "frost")
  let m = canonicalize(fr, effectFromJson(stmtJson))
  proc contrib(k: EncKeys, round: int): Event =
    let s = hx(edSign(k, m.bytes))
    let name = (if k.identity().ed == mallory.identity().ed: "frost:" & hx(mallory.identity().ed)
                else: contributorOf(fr, stmtJson, s))
    contributeEvent(id, name, s, round = round)
  let ev = @[policyDeclEvent(id, "frost"), proposeEvent(id, stmtJson),
             contrib(a, 1), contrib(b, 1), contrib(mallory, 1), contrib(a, 2), contrib(mallory, 2)]
  check("room FROST: a non-member in both rounds", ev, frFor, id, wantApprovals = 2, wantRound = 1)
  echo "3. room FROST: a non-member is on no surface, in either round OK"

# ── 4. btc.frost-bip445: a ChillDKG 2-of-3, contributions carry their round ───────
block:
  let kss = @[Keystore(newInMemoryKeystore(seed(1), seed(11))), Keystore(newInMemoryKeystore(seed(2), seed(12))),
              Keystore(newInMemoryKeystore(seed(3), seed(13)))]
  const L = "room-v/treasury"
  let hosts = kss.mapIt(it.frostHostPubkey(L))
  let params = SessionParams(hostpubkeys: hosts, t: 2)
  let pm1 = kss.mapIt(it.frostDkgStep1(L, params))
  let (cst, cmsg1) = coordinatorStep1(pm1, params)
  let pm2 = kss.mapIt(it.frostDkgStep2(L, params, cmsg1))
  let (cmsg2, _, rec) = coordinatorFinalize(cst, pm2)
  for k in kss: discard k.frostDkgFinalize(L, params, cmsg2)
  let acct = frostAccount("regtest", rec)
  let drv = newBtcFrostDriver(acct)
  let dFor: DriverFor = proc(kind: string): Driver = drv
  let utxos = @[BtcUtxo(txid: "11".repeat(32), vout: 0, value: 60_000, scriptPubKey: hx(acct.scriptPubKey))]
  let effectJson = buildFrostSpend(acct, utxos, "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", 40_000, feeRate = 2)
  let id = intentIdFor(effectJson, "btc-frost")
  let e = effectFromJson(effectJson)
  let hashes = drv.sighashesOf(e)
  let signers = @[0, 2]
  let nonces = signers.mapIt(kss[it].frostNonceCommit(L, id, rec, hashes))
  let r1 = signers.mapIt(round1Contribution(hosts[it], nonces[signers.find(it)]))
  let set = signers.mapIt((hosts[it], nonces[signers.find(it)]))
  let psig0 = kss[0].frostPartialSign(L, id, rec, signers, nonces, hashes)
  let r2host0 = round2Contribution(hosts[0], set, psig0)
  let stranger = newInMemoryKeystore(seed(9), seed(19)).frostHostPubkey(L)
  let ev = @[policyDeclEvent(id, "btc-frost"), proposeEvent(id, effectJson),
             contributeEvent(id, hx(hosts[0]), hx(r1[0].bytes), round = 1),
             contributeEvent(id, hx(hosts[2]), hx(r1[1].bytes), round = 1),
             contributeEvent(id, hx(stranger), hx(round1Contribution(stranger, nonces[0]).bytes), round = 1),
             contributeEvent(id, hx(hosts[0]), hx(r2host0.bytes), round = 2),
             # host 2's ROUND-1 payload, published as its round-2 contribution
             contributeEvent(id, hx(hosts[2]), hx(r1[1].bytes), round = 2)]
  check("btc FROST: a stranger in round 1, a round-1 payload replayed as round 2", ev, dFor, id,
        wantApprovals = 2, wantRound = 1)
  echo "4. btc FROST: a stranger and a wrong-round payload are on no surface OK"

# ── 5. the vote locus: LEZ multisig receipts, k=2 of {A, B, C} ───────────────────
block:
  proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
  let program = id32("program")
  let K = id32("create-key")
  let (A, B, C, D) = (id32("a"), id32("b"), id32("c"), id32("d"))
  let ra = RoomAccount(family: LezMultisigFamily, chain: "lez:local", address: hx(statePda(psLee02, program, K)),
                       label: "Treasury", signers: @[A, B, C].mapIt(hx(it)), threshold: 2,
                       config: $(%*{"program": hx(program), "createKey": hx(K), "pda": "lee-v0.2"}))
  let drv = newLezMultisigDriver(lezMultisigAccountOf(ra).account)
  let dFor: DriverFor = proc(kind: string): Driver = drv
  let act = LezAction(target: id32("token"), instruction: @[1'u32, 500, 0], accounts: @[id32("vault"), id32("to")],
                      pdaSeeds: @[vaultSeed(K)], authorized: @[0'u8])
  let ej = lezProposalEffect(1, act)
  let id = intentIdFor(ej, "lez-multisig")
  let m = canonicalize(drv, effectFromJson(ej))
  let m2 = canonicalize(drv, effectFromJson(lezProposalEffect(2, act)))
  let ev = @[policyDeclEvent(id, "lez-multisig"), proposeEvent(id, ej),
             contributeEvent(id, "lez:" & hx(B), hx(voteReceipt(B, 1, "ab".repeat(32), m).bytes)),
             contributeEvent(id, "lez:" & hx(D), hx(voteReceipt(D, 1, "ab".repeat(32), m).bytes)),    # not a member
             contributeEvent(id, "lez:" & hx(C), hx(voteReceipt(C, 2, "ab".repeat(32), m2).bytes))]   # another pointer
  check("LEZ vote receipts: a non-member, a vote for another pointer", ev, dFor, id, 1, 1)
  echo "5. LEZ: a non-member's receipt and a receipt for another pointer are on no surface OK"

# ── 6. the split (evm.split): every party it names must agree, and only a party can ──
# On ef16319 (#171 merged, #172 not yet) the card counted the creditor's agreement — then no
# party — and a room member's who is not a debtor; split_driver_test checks only the fold's
# state. Since exo-770 the creditor IS a party (their agreement is their word that payTo is
# theirs): the fold counts it, so every surface must; the outsider still counts nowhere.
block:
  proc idOf(k: EncKeys): string = hx(k.identity().toBytes())   # the room identity a split names
  proc edName(k: EncKeys): string = "ed:" & hx(k.identity().ed)
  let devon = encFromSeed(seed(21))       # fronted the bill: the creditor
  let ana = encFromSeed(seed(22))
  let jb = encFromSeed(seed(23))
  let you = encFromSeed(seed(24))
  let outsider = encFromSeed(seed(29))    # in the room, not at dinner
  const Chain = "eip155:31337"
  let drv = newSplitDriver(EvmSplitFamily, Chain, @[devon, ana, jb, you, outsider].mapIt(idOf(it)))
  let dFor: DriverFor = proc(kind: string): Driver = drv
  let ej = splitEffectJson(Chain, "ETH", "1200000000000000000", idOf(devon),
    "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
    @[ana, jb, you].mapIt(SplitShare(who: idOf(it), amount: "300000000000000000")), "Dinner")
  let policy = "evm-split@" & Chain
  let id = intentIdFor(ej, policy)
  let m = canonicalize(drv, effectFromJson(ej))
  proc agree(k: EncKeys): Event = contributeEvent(id, edName(k), hx(edSign(k, m.bytes)))
  let prop = @[policyDeclEvent(id, policy), proposeEvent(id, ej)]
  check("split: a debtor, the creditor, a member who is not a party",
        prop & @[agree(ana), agree(devon), agree(outsider)], dFor, id, wantApprovals = 2, wantRound = 2)
  check("split: every debtor agrees, not the creditor; the outsider still isn't counted",
        prop & @[agree(ana), agree(jb), agree(outsider), agree(you)], dFor, id, 3, 3)
  check("split: every debtor and the creditor; the outsider still isn't counted",
        prop & @[agree(ana), agree(jb), agree(outsider), agree(you), agree(devon)], dFor, id, 4, 4)
  echo "6. split: a non-party's agreement is on no surface; the creditor's is on every one OK"

echo "view_counts_fold_test: all OK"
