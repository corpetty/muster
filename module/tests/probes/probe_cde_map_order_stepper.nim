## derived-exo-d7c s2/c2: map keys serialize in bytewise-lexicographic order of
## their ENCODED bytes, never length-first, regardless of insertion order.
##
## STEPPER (exo-dbc): state is the insertion permutation; successors are the
## permutations one transposition away, so BFS from the spec's initial
## ("identity") reaches every insertion order. The key set is chosen so bytewise
## and RFC-8949 length-first orderings DISAGREE, so a length-first encoder fails
## every state rather than passing by coincidence.

import ../../src/dcbor/dcbor
import std/algorithm
import ./oracle_emit

# Keys whose encoded first bytes are 0x05, 0x1A, 0x61, 0x62 but whose encoded
# lengths are 1, 5, 2, 3 — so bytewise order (by first byte) and length-first
# order (by total length) are different permutations.
type KV = tuple[key, val: CborValue]
let entries: seq[KV] = @[
  (cbUint(5'u64),        cbText("five")),        # 0x05            (len 1)
  (cbUint(1000000'u64),  cbText("million")),     # 0x1A 000F4240   (len 5)
  (cbText("a"),          cbUint(1'u64)),          # 0x61 61         (len 2)
  (cbText("zz"),         cbUint(2'u64)),          # 0x62 7A 7A      (len 3)
]

proc lengthFirstCmp(x, y: seq[byte]): int =
  ## RFC 8949 §4.2.1 core-canonical: shorter encoded key first, then bytewise.
  if x.len != y.len: return cmp(x.len, y.len)
  cmpBytes(x, y)

proc expectedBytes(order: proc(a, b: seq[byte]): int): seq[byte] =
  var enc: seq[(seq[byte], seq[byte])]
  for e in entries: enc.add (encode(e.key), encode(e.val))
  enc.sort(proc(p, q: (seq[byte], seq[byte])): int = order(p[0], q[0]))
  result = @[0xA0'u8 or byte(entries.len)]  # map head (major 5), len < 24 → 1 byte
  for (kb, vb) in enc:
    result.add kb; result.add vb

let bytewiseExpected = expectedBytes(cmpBytes)
let lengthFirstExpected = expectedBytes(lengthFirstCmp)
doAssert bytewiseExpected != lengthFirstExpected,
  "test key set does not discriminate bytewise from length-first"

proc canonicalAt(perm: seq[int]): bool =
  var pairs: seq[(CborValue, CborValue)]
  for i in perm: pairs.add (entries[i].key, entries[i].val)
  let got = encode(cbMap(pairs))
  (got == bytewiseExpected) and (got != lengthFirstExpected)

proc state(perm: seq[int]): JsonNode =
  %*{"insertion_order": permString(perm), "matches_canonical_encoding": canonicalAt(perm)}

let arg = oracleStateArg()
let here = parsePerm(oracleStateStr(arg, "insertion_order", "identity"), entries.len)
var succ: seq[JsonNode]
for q in swapNeighbours(here): succ.add state(q)
emitSuccessors(succ)

if arg == nil:
  var perm = @[0, 1, 2, 3]
  sort(perm)
  while true:
    doAssert canonicalAt(perm),
      "map key order was not canonical bytewise-lex for some insertion order"
    if not nextPermutation(perm): break
