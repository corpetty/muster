## derived-exo-f60 s5/c5: anonymity covers everything retained, not just what's
## shown. Walk the ENTIRE declared retention schema — log records, reduced state,
## state events, cache, export, crash dump — and no reachable field is derived
## from signer identity (and no signature-valued field is member-bound; the
## anonymous client retains none). STEPPER (exo-dbc): state is (record_type, field_index) into the declared
## retention schema; successors are the next field within the record type and the
## first field of every other record type, so BFS walks the ENTIRE schema.

import ../../src/intents/anon_state
import ./oracle_emit

let schema = retentionSchema()

proc recordTypes(): seq[string] =
  for f in schema:
    if f.recordType notin result: result.add f.recordType

proc fieldsOf(rt: string): seq[RetentionField] =
  for f in schema:
    if f.recordType == rt: result.add f

proc state(rt: string, idx: int): JsonNode =
  let fs = fieldsOf(rt)
  doAssert idx in 0 ..< fs.len, "field_index out of range for " & rt
  %*{"record_type": rt, "field_index": idx,
     "identity_derived_field": fs[idx].identityDerived}

let arg = oracleStateArg()
let hereType = oracleStateStr(arg, "record_type", "log_record")
let hereIdx = oracleStateInt(arg, "field_index", 0)

var succ: seq[JsonNode]
if hereIdx + 1 < fieldsOf(hereType).len:
  succ.add state(hereType, hereIdx + 1)
for rt in recordTypes():
  if rt != hereType: succ.add state(rt, 0)
emitSuccessors(succ)

if arg == nil:
  for f in schema:
    doAssert not f.identityDerived, "a retained field is derived from signer identity"
