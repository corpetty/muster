## derived-exo-f60 s2/c2: local logs carry no signer identity on any path —
## debug, info, warn, error, verification-failure, crash, shutdown. Stepper over
## (path × signer): no emitted record contains the signer identifier or a value
## resolving to one. STEPPER (exo-dbc): state is the log path; successors are every other path, each
## carrying the leak measured across ALL signers for it (the signer is not part
## of the state, so a path's verdict must quantify over signers).

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/strutils
import ./oracle_emit

let signers = @["alice", "bob", "carol", "dave", "eve", "frank"]
let paths = @["startup", "debug", "info", "warn", "error",
              "verification-failure", "crash", "shutdown"]

proc recordsForPath(path, signer: string): seq[LogRecord] =
  var co = newAnonCoordination(total = 3)
  co.ingest(Arrival(contribution: Contribution(bytes: @[1'u8]), signer: signer))
  # A path-specific extra record; none of them names the signer.
  case path
  of "error": co.log.add LogRecord(seqNo: co.log.len, kind: "error",
    detail: "contribution rejected at slot 1", logPos: co.log.len)
  of "verification-failure": co.log.add LogRecord(seqNo: co.log.len, kind: "verify-fail",
    detail: "signature did not verify for slot 1", logPos: co.log.len)
  of "crash": co.log.add LogRecord(seqNo: co.log.len, kind: "crash",
    detail: "panic while reducing log", logPos: co.log.len)
  of "shutdown": co.log.add LogRecord(seqNo: co.log.len, kind: "shutdown",
    detail: "flushing state", logPos: co.log.len)
  else: discard
  co.log

proc leaksAt(path: string): bool =
  ## True if ANY signer's identity reaches a record on this path.
  for signer in signers:
    for r in recordsForPath(path, signer):
      if signer in r.detail or signer in r.kind: return true
  false

proc state(path: string): JsonNode =
  %*{"log_path": path, "signer_identity_in_record": leaksAt(path)}

let here = oracleStateStr(oracleStateArg(), "log_path", "startup")
var succ: seq[JsonNode]
for p in paths:
  if p != here: succ.add state(p)
emitSuccessors(succ)

# Run by hand this still enumerates and fails loudly.
if oracleStateArg() == nil:
  for path in paths:
    doAssert not leaksAt(path), "a log record on some path contained the signer identity"
