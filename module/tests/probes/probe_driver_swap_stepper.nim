## derived-exo-2dc s3/c3: swapping in a different driver (different round count,
## membership model, finality type) requires no core code changes — the core
## adapts purely from describe().
##
## STEPPER (exo-dbc): state is the driver configuration; successors are every
## other configuration. The SAME core code (startCollection / submit) must adapt
## to each: its policy echoes describe() and it closes in exactly that config's
## round count. The spec's initial id "default" is the 2-round anonymous
## immediate-finality configuration.

import ../../src/drivers/driver
import std/strutils
import ./oracle_emit

const Rounds = [1, 2, 3]
const Memberships = [mmAnonymous, mmNamed]
const Finalities = [finImmediate, finProbabilistic, finExternal]

proc configId(r: int, m: MembershipModel, f: FinalityType): string =
  "r" & $r & "-" & $m & "-" & $f

proc configIds(): seq[string] =
  for r in Rounds:
    for m in Memberships:
      for f in Finalities: result.add configId(r, m, f)

const DefaultConfig = "r2-anonymous-immediate"

proc adaptsCorrectly(id: string): bool =
  let parts = id.split('-')
  doAssert parts.len == 3, "malformed driver_config_id: " & id
  let rounds = parseInt(parts[0][1 .. ^1])
  var membership = mmAnonymous
  for m in Memberships:
    if $m == parts[1]: membership = m
  var finality = finImmediate
  for f in Finalities:
    if $f == parts[2]: finality = f

  let drv = newStubDriver(rounds = rounds, threshold = 2,
                          membership = membership, finality = finality)
  var col = startCollection(drv)
  if col.roundCount != rounds or col.membershipDispatch != membership or
     col.finalityHandling != finality: return false
  for rnd in 1 .. rounds:
    for k in 1 .. 2:
      col.submit(drv, Contribution(bytes: @[1'u8]))
    if rnd < rounds and col.complete: return false   # closed early
  col.complete                                       # and closed at all

proc state(id: string): JsonNode =
  %*{"driver_config_id": id, "adapted_correctly": adaptsCorrectly(id)}

let arg = oracleStateArg()
var here = oracleStateStr(arg, "driver_config_id", "default")
if here == "default": here = DefaultConfig
var succ: seq[JsonNode]
for id in configIds():
  if id != here: succ.add state(id)
emitSuccessors(succ)

if arg == nil:
  for id in configIds():
    doAssert adaptsCorrectly(id), "core failed to adapt to a swapped driver configuration"
