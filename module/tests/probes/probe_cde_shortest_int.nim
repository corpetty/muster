## derived-exo-d7c s3/c3: integers use the shortest valid encoding, no padding.
## For each magnitude-boundary value, compare the encoder's output length to an
## independently computed canonical minimum. Emits
## {"encoded_len": N, "canonical_min_len": M} and fails if they ever differ.

import ../../src/dcbor/dcbor
import ./oracle_emit

var obs: seq[JsonNode]

proc canonicalMinLen(arg: uint64): int =
  ## Head-only length for a bare integer: 1 + the shortest additional-info width.
  if arg < 24'u64: 1
  elif arg <= 0xFF'u64: 2
  elif arg <= 0xFFFF'u64: 3
  elif arg <= 0xFFFF_FFFF'u64: 5
  else: 9

var allMinimal = true
proc check(v: CborValue, arg: uint64) =
  let encodedLen = encode(v).len
  let minLen = canonicalMinLen(arg)
  if encodedLen != minLen: allMinimal = false
  obs.add %*{"encoded_len": encodedLen, "canonical_min_len": minLen}

# Unsigned: values straddling every width boundary (23/24, 255/256, 65535/65536,
# 2^32-1/2^32) plus the extremes.
for u in [0'u64, 1, 23, 24, 25, 255, 256, 65535, 65536,
          4294967295'u64, 4294967296'u64, high(uint64)]:
  check(cbUint(u), u)

# Negative: major-1 argument is -1 - value, so the same boundaries apply to it.
for i in [int64(-1), -24, -25, -256, -257, -65536, -65537, low(int64)]:
  let arg = uint64(-(i + 1))
  check(cbInt(i), arg)

emitTrials(obs)
doAssert allMinimal, "an integer was encoded wider than its canonical minimum"
