## FROST on Bitcoin mainnet is refused (exo-863, audit S8). module/src/frost/ is
## demonstration-grade: its scalar and point arithmetic is not constant time (frost/secp.nim),
## and the "production gate" it is held behind existed only in comments. Nothing stopped a
## ceremony on mainnet, or this client deriving and acting from a mainnet FROST account
## another member disclosed. Now:
##   1. a FROST account is never derived on mainnet, whatever its recovery data;
##   2. a ceremony is never opened on mainnet;
##   3. a member never takes a step in a mainnet ceremony someone else opened, so no host
##      key share of theirs is ever made for one;
##   4. test networks are unchanged.
## Needs the secp closure + stint + libsodium — see tests/README.md.

import std/[strutils, sequtils]
import ../src/log/log
import ../src/drivers/btc_frost
import ../src/coordination/[session, aggregate]
import ./probes/live_room

block:
  doAssert frostNetworkRefusal("mainnet").len > 0
  doAssert frostNetworkRefusal("regtest") == "" and frostNetworkRefusal("signet") == "" and
           frostNetworkRefusal("testnet") == "" and frostNetworkRefusal("testnet4") == ""
  doAssert frostNetworkRefusal("lez:testnet") == "", "LEZ has no mainnet to refuse"
  var raised = false
  try: discard frostAccount("mainnet", @[byte 1, 2, 3])
  except CatchableError as e:
    raised = "mainnet" in e.msg
  doAssert raised, "no FROST account is derived on mainnet"
  echo "1. no FROST account on mainnet OK"

var r = newRoom3("/muster/1/frost-mainnet-gate/proto")

block:
  var raised = false
  try: discard frostCeremonyOpen(r.alice, "main", "mainnet", 2, 3)
  except CatchableError: raised = true
  doAssert raised, "a ceremony is not opened on mainnet"
  r.alice.poll()
  doAssert not ceremonyView(r.alice.log.allEvents(), "main").open
  echo "2. no ceremony opened on mainnet OK"

block:
  # another client (an older build, or a member who changed theirs) publishes the open itself
  r.alice.publish(Event(key: "frost/main2/open", value: """{"network":"mainnet","t":2,"n":2}"""))
  for s in [r.alice, r.bob, r.carol]: s.poll()
  doAssert ceremonyView(r.bob.log.allEvents(), "main2").open
  let before = r.bob.log.allEvents().len
  let step = frostCeremonyStep(r.bob, bobKs, "main2")
  doAssert step.startsWith("refused"), "a member takes no step in a mainnet ceremony, got: " & step
  r.bob.poll()
  doAssert r.bob.log.allEvents().len == before, "and publishes nothing for it"
  doAssert not r.bob.log.allEvents().anyIt(it.key.startsWith("frost/main2/pmsg")),
    "no step message of theirs exists"
  echo "3. no step taken in a mainnet ceremony another member opened OK"

block:
  discard frostCeremonyOpen(r.alice, "reg", "regtest", 2, 3)
  r.alice.poll()
  doAssert ceremonyView(r.alice.log.allEvents(), "reg").open, "regtest ceremonies open as before"
  echo "4. test networks unchanged OK"

echo "frost_mainnet_gate_test: all OK"
