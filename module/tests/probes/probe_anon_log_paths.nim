## derived-exo-f60 s2/c2: local logs carry no signer identity on any path —
## debug, info, warn, error, verification-failure, crash, shutdown. Stepper over
## (path × signer): no emitted record contains the signer identifier or a value
## resolving to one. Emits {"log_path": "...", "signer_identity_in_record": ...}.

import ../../src/drivers/driver
import ../../src/intents/anon_state
import std/strutils

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

var allClean = true
for path in paths:
  for signer in signers:
    var leak = false
    for r in recordsForPath(path, signer):
      if signer in r.detail or signer in r.kind: leak = true
    if leak: allClean = false
    echo "{\"log_path\": \"", path, "\", \"signer_identity_in_record\": ",
         (if leak: "true" else: "false"), "}"

doAssert allClean, "a log record on some path contained the signer identity"
