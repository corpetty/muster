## Who may run an executable module action (exo-3b3.18, audit P4-06).
##
## An invoke intent runs, once the room endorsed it, with the module tokens of whoever runs
## it (coordinate_execute). So only a member whose own endorsement the fold counts runs it:
## they already agreed to exactly this call. Anyone else, the proposer who never approved
## included, is refused, and the card offers Run only to an endorser (behind a confirmation
## that shows the call). The fold decides who endorsed (attest.approvalGrades), never a
## claim in the request.

import ../log/log
import ../drivers/driver
import ./intent_events     # DriverFor
import ../crypto/curve25519
import ./attest

proc runRefusal*(events: seq[Event], driverFor: DriverFor, intentId: string,
                 me: EncIdentity, myNames: seq[string]): string =
  ## "" when THIS member (`me`, under the names its approvals carry) endorsed `intentId` and
  ## the fold counts that endorsement; otherwise why they may not run it.
  var whos: seq[string]
  for g in approvalGrades(events, driverFor, intentId):
    if g.grade != agRejected and g.who notin whos: whos.add g.who
  if whos.len == 0: return "no one has endorsed this action yet"
  if not approvedByMe(events, intentId, whos, me, myNames):
    return "only a member who endorsed this action runs it: endorse it first"
  ""
