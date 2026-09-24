## Accounts live in the room, disclosed by members (exo-a50.1.3; seam S1 of
## docs/design/multisig-landscape.md; decision 2026-09-23).
##
## Before this, every Safe intent resolved to ONE module-global Safe (the anvil
## fixture): a room could not hold two accounts, and nothing in the room said which
## account an intent spends from. Now an account exists to a room only once a named
## member DISCLOSES it into the log, every reader can check the disclosure against the
## chain, and an account-bound intent names its account in its policy
## ("safe@<CAIP-10>"), so the intent id commits to it. Held here:
##   1. the disclosure fold: one account per CAIP-10 id, every discloser named, a
##      disagreeing second disclosure flagged (the first, in canonical order, governs),
##      reorder/duplicate-stable (invariant 4);
##   2. resolution: two Safes on two chains in ONE room resolve to two drivers, each
##      its own chain, account and owner set; a bare "safe", an undisclosed account, an
##      account of the wrong family, or an account on a room kind is UNSUPPORTED —
##      never the module's fixture; eip191 attests with the account's signers;
##   3. the chain check: verified / disagrees (naming what differs) / unknown;
##   4. live: a member discloses, proposes under the account, two owners approve in-app
##      and it reaches executable; the same effect under the other Safe is another
##      intent, and an approval for one never counts for the other.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, algorithm, sequtils, strutils]
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/kinds
import ../src/drivers/threshold
import ../src/coordination/accounts
import ./probes/live_room

const SafeB = "0x00000000000000000000000000000000000000b0"
const Owners = ["0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
                "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
                "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"]
let aliceId = "alice-enc-identity"
let bobId = "bob-enc-identity"

proc safeA(threshold = 2, label = "Ops Treasury"): RoomAccount =
  RoomAccount(family: "evm.safe", chain: "eip155:31337", address: SafeAddr.toLowerAscii(),
              label: label, signers: @Owners, threshold: threshold)
proc safeOnBase(): RoomAccount =
  RoomAccount(family: "evm.safe", chain: "eip155:8453", address: SafeB,
              label: "Base Treasury", signers: @Owners, threshold: 2)

let roomBuild = proc(kind: string): Driver = newThresholdDriver(@[], 1)

# ── 1. the disclosure fold ──────────────────────────────────────────────────────
block:
  let a1 = accountDiscloseEvent(safeA(), aliceId)
  let a2 = accountDiscloseEvent(safeA(), bobId)
  let accts = reduceAccounts(@[a1, a2])
  doAssert accts.len == 1
  let a = accts[0]
  doAssert a.id == "eip155:31337:" & SafeAddr.toLowerAscii(), a.id
  doAssert a.id == accountId("eip155:31337", SafeAddr), "the id is CAIP-10 with a lowercased address"
  doAssert sorted(a.disclosedBy) == sorted(@[aliceId, bobId]), $a.disclosedBy
  doAssert not a.conflict and a.threshold == 2 and a.signers == @Owners
  # a second member disclosing a different threshold for the same account: flagged,
  # and the first disclosure in canonical order governs — never silently merged
  let odd = accountDiscloseEvent(safeA(threshold = 1), "carol-enc-identity")
  let c = reduceAccounts(@[a1, a2, odd])
  doAssert c.len == 1 and c[0].conflict, "disagreeing disclosures must be flagged"
  doAssert c[0].threshold == reduceAccounts(@[odd, a2, a1])[0].threshold,
    "which disclosure governs is a function of the event SET (canonical order), not arrival"
  # invariant 4: reorder + duplicate → identical fold
  let x = reduceAccounts(@[a1, a2, odd, a1])
  let y = reduceAccounts(@[odd, a1, a2])
  doAssert $accountsJson(x) == $accountsJson(y)
  # two accounts are two entries
  doAssert reduceAccounts(@[a1, accountDiscloseEvent(safeOnBase(), bobId)]).len == 2
  echo "1. disclosures fold to one account per CAIP-10 id, disclosers named, disagreement flagged, order-free OK"

# ── 2. resolution: account-bound policies ────────────────────────────────────────
block:
  let accts = reduceAccounts(@[accountDiscloseEvent(safeA(), aliceId),
                               accountDiscloseEvent(safeOnBase(), bobId)])
  let aId = accountId("eip155:31337", SafeAddr)   # canonical order, not insertion, orders accts
  let pA = qualify("safe", aId)
  let pB = qualify("safe", accountId("eip155:8453", SafeB))
  doAssert pA == "safe@eip155:31337:" & SafeAddr.toLowerAscii()
  doAssert splitPolicy(pA) == ("safe", aId)
  doAssert isKnownKind(pA), "a qualified policy is its kind"
  let dA = driverForPolicy(pA, accts, roomBuild)
  let dB = driverForPolicy(pB, accts, roomBuild)
  doAssert dA.profile().family == "evm.safe" and dB.profile().family == "evm.safe"
  doAssert dA.profile().chain == "eip155:31337" and dB.profile().chain == "eip155:8453"
  doAssert dA.profile().account == aId and dB.profile().account == accountId("eip155:8453", SafeB)
  doAssert dA.profile().k == 2 and dA.profile().n == 3
  for bad in ["safe",                                              # no account
              qualify("safe", accountId("eip155:1", SafeAddr)),    # not disclosed here
              qualify("threshold", aId),                  # a room kind takes no account
              qualify("squads", aId)]:                    # not a kind this client has
    doAssert driverForPolicy(bad, accts, roomBuild) of UnsupportedDriver, bad & " must be unsupported"
  doAssert not (driverForPolicy("threshold", accts, roomBuild) of UnsupportedDriver)
  let att = driverForPolicy(qualify("eip191", aId), accts, roomBuild)
  doAssert att.profile().family == "room.eip191-attest" and att.profile().n == 3,
    "an attestation is by the disclosed account's signers"
  doAssert kindNeedsAccount("safe") and kindNeedsAccount("eip191") and not kindNeedsAccount("threshold")
  echo "2. two Safes on two chains resolve to two drivers; bare / undisclosed / wrong-kind policies are unsupported OK"

# ── 3. the chain check ─────────────────────────────────────────────────────────
block:
  let a = reduceAccounts(@[accountDiscloseEvent(safeA(), aliceId)])[0]
  doAssert checkAccount(a, (known: true, signers: @Owners, threshold: 2, detail: "")).status == acVerified
  let fewer = checkAccount(a, (known: true, signers: @Owners[0 .. 1], threshold: 2, detail: ""))
  doAssert fewer.status == acDisagrees and Owners[2] in fewer.detail, fewer.detail
  let thr = checkAccount(a, (known: true, signers: @Owners, threshold: 1, detail: ""))
  doAssert thr.status == acDisagrees and "threshold" in thr.detail, thr.detail
  let unk = checkAccount(a, (known: false, signers: @[], threshold: 0, detail: "no getOwners()"))
  doAssert unk.status == acUnknown and "getOwners" in unk.detail
  # owner order and address case never make a match disagree
  doAssert checkAccount(a, (known: true, signers: Owners.reversed().mapIt(it.toUpperAscii().replace("0X", "0x")),
                            threshold: 2, detail: "")).status == acVerified
  echo "3. the chain check: verified / disagrees (naming what differs) / unknown OK"

# ── 4. live: disclose → propose under the account → two owners → executable ─────
block:
  var r = newRoom("/muster/1/accounts-live/proto")
  r.alice.publish(accountDiscloseEvent(safeA(), aliceId))
  r.alice.publish(accountDiscloseEvent(safeOnBase(), aliceId))
  r.bob.poll()
  let resolverOf = proc(s: CoordinationSession): DriverFor =
    (proc(policy: string): Driver = driverForPolicy(policy, reduceAccounts(s.log.allEvents()), roomBuild))
  let accts = reduceAccounts(r.alice.log.allEvents())
  let pA = qualify("safe", accountId("eip155:31337", SafeAddr))
  let pB = qualify("safe", accountId("eip155:8453", SafeB))
  let eff = effectFor("safe", 5, "\"sources\":{\"value\":\"read\",\"nonce\":\"read\"}")
  let idA = liveProposeIntent(r.alice, aliceKs, resolverOf(r.alice), pA, eff, int64(Now), 1,
                              account = SafeAddr, ttlSec = Ttl)
  let idB = liveProposeIntent(r.alice, aliceKs, resolverOf(r.alice), pB, eff, int64(Now), 2,
                              account = SafeB, ttlSec = Ttl)
  doAssert idA != idB, "the same effect on two Safes is two intents (the id commits to the account)"
  for id in [idA, idB]:
    r.alice.publish(readEvent(id, "value", "rpc://probe", "5"))
    r.alice.publish(readEvent(id, "nonce", "rpc://probe", "0"))
  doAssert liveContribute(r.alice, aliceKs, resolverOf(r.alice), idA, "", "", bindCtx(), Now) == "collecting"
  r.bob.poll()
  doAssert liveContribute(r.bob, bobKs, resolverOf(r.bob), idA, "", "", bindCtx(), Now) == "executable",
    "two of Safe A's owners approve in-app → executable"
  # alice's signature for A, replayed onto B's intent, never counts (different EIP-712 domain)
  let evs = r.alice.log.allEvents()
  var sigA: Event
  for e in evs:
    if e.key.startsWith("intent/" & idA & "/sig/"): sigA = e
  r.alice.publish(contributeEvent(idB, sigA.key.split('/')[3], sigA.value))
  doAssert intentState(r.alice.log.allEvents(), resolverOf(r.alice), idB) notin ["executable", "submitted", "final"],
    "an approval for one account never counts for another"
  # an intent under an account nobody disclosed is refused outright
  doAssert liveProposeIntent(r.alice, aliceKs, resolverOf(r.alice),
    qualify("safe", accountId("eip155:1", SafeAddr)), eff, int64(Now), 3,
    account = SafeAddr, ttlSec = Ttl) == "unsupported-driver"
  doAssert accts.len == 2
  echo "4. live: disclose → propose under the account → two owners → executable; accounts never share approvals OK"

echo "accounts_test: all OK"
