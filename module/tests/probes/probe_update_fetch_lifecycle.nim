## derived-exo-8dc s6/c6: no automatic update fetch — updates are manual, or come
## from an explicitly enabled (default-off) signed feed.
##
## STEPPER (exo-dbc): state is the lifecycle stage; successors are every other
## stage. Each stage fixes the feed configuration a client would actually be in
## at that point, and the verdict is whether a fetch could happen without the
## user having explicitly enabled the feed.

import ../../src/transport/infra
import ./oracle_emit

const Stages = ["first_launch", "idle", "auto_trigger", "manual_check",
                "user_enabled_feed", "user_enabled_unsigned", "post_update"]

proc feedEnabledAt(stage: string): bool =
  ## Default-OFF everywhere the user has not explicitly turned the feed on.
  stage in ["user_enabled_feed", "user_enabled_unsigned", "post_update"]

proc signedFeedAt(stage: string): bool =
  stage != "user_enabled_unsigned"

proc unconsentedAt(stage: string): bool =
  var cfg = newConfig(@["feed"])
  cfg.updateFeedEnabled = feedEnabledAt(stage)
  let fetched = wouldFetchUpdate(cfg, signedFeedAt(stage))
  # A fetch without explicit enablement is unconsented — default-off means an
  # un-enabled stage must never fetch, whatever triggers it.
  fetched and not feedEnabledAt(stage)

proc state(stage: string): JsonNode =
  %*{"lifecycle": stage, "unconsented_update_fetch": unconsentedAt(stage)}

let arg = oracleStateArg()
let here = oracleStateStr(arg, "lifecycle", "first_launch")
var succ: seq[JsonNode]
for s in Stages:
  if s != here: succ.add state(s)
emitSuccessors(succ)

if arg == nil:
  for s in Stages:
    doAssert not unconsentedAt(s), "an update was fetched without explicit consent"
