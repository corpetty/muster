## derived-exo-d7c s1/c1: encoding the same value twice, in any construction
## order, always yields identical bytes. Emits {"bytes_equal": ...} per case
## (the trace_invariant field) and fails the process if any case diverges.

import ../../src/dcbor/dcbor
import std/algorithm
import ./oracle_emit

var obs: seq[JsonNode]

var allStable = true
proc emit(b: bool) =
  if not b: allStable = false
  obs.add flag("bytes_equal", b)
# 1. Re-encoding a value is a pure function of the value.
let samples = @[
  cbUint(0'u64), cbUint(23'u64), cbUint(24'u64), cbUint(255'u64), cbUint(256'u64),
  cbUint(65535'u64), cbUint(65536'u64), cbUint(4294967295'u64), cbUint(4294967296'u64),
  cbUint(high(uint64)),
  cbInt(-1), cbInt(-24), cbInt(-256), cbInt(-65536), cbInt(low(int64)),
  cbText(""), cbText("muster"), cbBytes(@[]), cbBytes(@[0'u8, 255'u8, 128'u8]),
  cbBool(true), cbBool(false), cbNull(),
  cbArray(@[cbUint(1'u64), cbText("x"), cbBool(false), cbNull()]),
]
for v in samples:
  emit(encode(v) == encode(v))

# 2. The same map content built in every insertion order encodes identically.
let keys = @["env", "acct", "slot", "expiry"]
proc buildMap(order: seq[int]): CborValue =
  var pairs: seq[(CborValue, CborValue)]
  for k in order:
    pairs.add (cbText(keys[k]), cbUint(uint64(k + 1)))
  cbMap(pairs)

let reference = encode(buildMap(@[0, 1, 2, 3]))
var perm = @[0, 1, 2, 3]
sort(perm)
while true:
  emit(encode(buildMap(perm)) == reference)
  if not nextPermutation(perm): break


emitTrials(obs)
doAssert allStable, "re-encoding was not byte-stable"
