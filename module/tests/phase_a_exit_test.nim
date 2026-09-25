## Phase A exit (exo-a50.1.7; docs/design/multisig-landscape.md §8): "two Safes on two
## chains in two rooms, no globals; every card row comes only from Driver.profile()".
##
## Written before the card slice it gates (exo-a50.1.6), per the working agreement.
## Held here, headless, over the real coordination path (two rooms on the local
## transport, two owners each):
##   1. two rooms each hold their OWN Safe — disclosed by a member, on its own chain —
##      and each takes its own proposal to executable; each room's settlement targets
##      its own Safe on its own chain;
##   2. no globals: an account disclosed in one room cannot be acted from in the other
##      (the policy resolves unsupported there), and no room intent resolves to a
##      Safe nobody disclosed;
##   3. the card rows are a pure function of the profile: the same fixed rows, in the
##      same order, for EVERY family on the kind list; each room's rows name its own
##      chain and never the other's; rows differ exactly where profiles differ;
##   4. the rows carry their credibility: a Safe whose modules were not read says its
##      threshold is motivational (ways around it unknown), a room threshold is
##      imperative, an unbound chain signature would be exposed.
## Needs the secp closure + libsodium (+ stint) — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/kinds
import ../src/drivers/registry
import ../src/drivers/threshold
import ../src/coordination/accounts
import ../src/coordination/card_rows
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/settlement/settlement
import ./probes/live_room

const SafeB = "0x00000000000000000000000000000000000000b0"
const Owners = ["0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
                "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"]
let roomBuild = proc(kind: string): Driver = newThresholdDriver(@[], 1)
proc resolverOf(s: CoordinationSession): DriverFor =
  (proc(policy: string): Driver = driverForPolicy(policy, reduceAccounts(s.log.allEvents()), roomBuild))

let acctA = RoomAccount(family: "evm.safe", chain: "eip155:31337", address: SafeAddr.toLowerAscii(),
                        label: "Ops (anvil)", signers: @Owners, threshold: 2)
let acctB = RoomAccount(family: "evm.safe", chain: "eip155:8453", address: SafeB,
                        label: "Treasury (Base)", signers: @Owners, threshold: 2)
let idA = accountId(acctA.chain, acctA.address)
let idB = accountId(acctB.chain, acctB.address)

proc runRoom(topic: string, acct: RoomAccount, n: int): (Room, string) =
  var r = newRoom(topic)
  r.alice.publish(accountDiscloseEvent(acct, "alice"))
  r.bob.poll()
  let policy = qualify("safe", accountId(acct.chain, acct.address))
  let eff = effectFor("safe", n, "\"sources\":{\"value\":\"read\",\"nonce\":\"read\"}")
  let id = liveProposeIntent(r.alice, aliceKs, resolverOf(r.alice), policy, eff, int64(Now), 1,
                             account = acct.address, ttlSec = Ttl)
  r.alice.publish(readEvent(id, "value", "rpc://probe", $n))
  r.alice.publish(readEvent(id, "nonce", "rpc://probe", "0"))
  doAssert liveContribute(r.alice, aliceKs, resolverOf(r.alice), id, "", "", bindCtx(), Now) == "collecting"
  r.bob.poll()
  doAssert liveContribute(r.bob, bobKs, resolverOf(r.bob), id, "", "", bindCtx(), Now) == "executable"
  (r, id)

# ── 1. two rooms, two Safes, two chains, each to executable ──────────────────────
let (roomA, intentA) = runRoom("/muster/1/exit-a/proto", acctA, 5)
let (roomB, intentB) = runRoom("/muster/1/exit-b/proto", acctB, 5)
let drvA = resolverOf(roomA.alice)(qualify("safe", idA))
let drvB = resolverOf(roomB.alice)(qualify("safe", idB))
block:
  doAssert drvA.profile().chain == "eip155:31337" and drvB.profile().chain == "eip155:8453"
  doAssert intentA != intentB, "the same effect on two accounts is two intents"
  let relayer = Account(chain: "evm:31337", form: afPublic, id: Owners[2])
  let stA = settlementFor(drvA, ChainAdapter(), relayer)
  let stB = settlementFor(drvB, ChainAdapter(), relayer)
  doAssert stA != nil and stB != nil
  echo "1. two rooms each hold their own disclosed Safe on its own chain, each proposal reaches executable OK"

# ── 2. no globals ───────────────────────────────────────────────────────────────
block:
  doAssert resolverOf(roomA.alice)(qualify("safe", idB)) of UnsupportedDriver,
    "an account disclosed in room B cannot be acted from in room A"
  doAssert resolverOf(roomB.alice)(qualify("safe", idA)) of UnsupportedDriver,
    "and vice versa"
  doAssert resolverOf(roomA.alice)("safe") of UnsupportedDriver, "a bare safe resolves to no global Safe"
  doAssert resolverOf(roomA.alice)(qualify("safe", accountId("eip155:1", SafeAddr))) of UnsupportedDriver,
    "an account nobody disclosed is nothing"
  echo "2. no globals: accounts do not cross rooms, and nothing resolves to an undisclosed Safe OK"

# ── 3. card rows: a pure function of the profile, fixed rows for every family ────
let rowKeys = @["where", "sign", "binding", "ordering", "expiry", "collect", "chain", "cost", "change", "bypass"]
block:
  let rowsA = cardRows(drvA.profile())
  let rowsB = cardRows(drvB.profile())
  doAssert rowsA.mapIt(it.key) == rowKeys, $rowsA.mapIt(it.key)
  doAssert $cardRowsJson(rowsA) == $cardRowsJson(cardRows(drvA.profile())), "pure"
  let textA = rowsA.mapIt(it.text).join(" | ")
  let textB = rowsB.mapIt(it.text).join(" | ")
  doAssert "eip155:31337" in textA and "eip155:8453" notin textA, textA
  doAssert "eip155:8453" in textB and "eip155:31337" notin textB, textB
  doAssert "2 of 3" in textA
  # rows differ exactly where the profiles differ: two Safes differ only by chain/account
  for i in 0 ..< rowKeys.len:
    if rowsA[i].text != rowsB[i].text:
      doAssert rowsA[i].key in ["where", "binding"], "only chain-naming rows differ: " & rowsA[i].key
  # every kind on the one list, whatever its family, answers the same rows in the same order
  for k in Kinds:
    let cfg = (if k.kind == "safe": %*{"chainId": 31337, "safe": SafeAddr, "owners": @Owners, "threshold": 2}
               elif k.kind == "eip191": %*{"signers": @Owners, "threshold": 1}
               elif k.kind in ["btc-p2wsh", "btc-tapscript"]:
                 %*{"network": "regtest", "k": 2, "keys": ["0307b8ae49ac90a048e9b53357a2354b3334e9c8bee813ecb98e99a7e07e8c3ba3",
                                                          "03b28f0c28bfab54554ae8c658ac5c3e0ce6e79ad336331f78c428dd43eea8449b"]}
               elif k.kind == "lez-multisig":
                 %*{"chain": "lez:local", "pda": "lee-v0.2", "program": repeat("aa", 32), "createKey": repeat("0b", 32),
                   "threshold": 2, "members": [repeat("01", 32), repeat("02", 32), repeat("03", 32)]}
               elif k.kind == "btc-frost": %*{"network": "regtest", "recovery": frostTestRecoveryHex()}
               elif k.kind == "lez-frost": %*{"chain": "lez:local", "recovery": frostTestRecoveryHex()}
               else: %*{"roster": [], "k": 1})
    let rows = cardRows(newDriver(k.kind, cfg).profile())
    doAssert rows.mapIt(it.key) == rowKeys, k.kind & ": " & $rows.mapIt(it.key)
    doAssert rows.allIt(it.text.len > 0 and it.label.len > 0), k.kind & " left a row empty"
  # an undeclared driver's rows say so, never a guessed family
  let unsup = cardRows(newUnsupportedDriver("squads").profile())
  doAssert unsup.mapIt(it.key) == rowKeys and unsup.allIt("not" in it.text.toLowerAscii() or "unknown" in it.text.toLowerAscii()),
    "an undeclared family's rows say they do not know: " & unsup.mapIt(it.text).join(" | ")
  echo "3. the same fixed rows for every family, a pure function of the profile; each room names only its own chain OK"

# ── 4. credibility travels with the row ─────────────────────────────────────────
block:
  let where = cardRows(drvA.profile()).filterIt(it.key == "where")[0]
  doAssert where.credibility == "motivational" and where.party.len > 0,
    "a Safe whose modules were not read: ways around the rule unknown → motivational, party named"
  var read = drvA.profile()
  read.bypassesKnown = true
  doAssert cardRows(read).filterIt(it.key == "where")[0].credibility == "imperative",
    "no modules, no guard (read) → the chain enforces the threshold"
  var withModule = read
  withModule.bypasses = @["module 0xabc…"]
  doAssert cardRows(withModule).filterIt(it.key == "where")[0].credibility == "motivational"
  let room = cardRows(newDriver("threshold", %*{"roster": [], "k": 1}).profile())
  doAssert room.filterIt(it.key == "where")[0].credibility == "imperative"
  var unbound = drvA.profile()
  unbound.binding = bdNone
  doAssert cardRows(unbound).filterIt(it.key == "binding")[0].credibility == "exposed"
  doAssert cardRows(drvA.profile()).filterIt(it.key == "chain")[0].credibility == "exposed",
    "a Safe names its signers to anyone reading the chain"
  echo "4. every row carries its credibility (imperative / motivational / exposed) with the party named OK"

echo "phase_a_exit_test: two Safes, two chains, two rooms, no globals, card rows only from the profile — all OK"
