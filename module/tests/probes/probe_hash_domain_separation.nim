## derived-exo-449 s2/c2: hashing the same underlying content under two different
## domains always produces different digests — domain separation is load-bearing.
##
## For each content payload, digest it under every distinct domain and assert the
## resulting digests are all distinct. Emits {"digests": [...]} per payload (the
## trace_invariant's `distinct` collection) and fails if any two collide.

import ../../src/dcbor/dcbor
import ../../src/hashing/hash_input
import std/sets

let domains = @[
  "muster.event.transfer.v1",
  "muster.event.membership.v1",
  "muster.event.fact.v1",
  "muster.materialization.v1",
  "",                        # empty domain is still a distinct domain
]

# Distinct underlying content payloads, each hashed under every domain above.
let contents: seq[seq[(string, CborValue)]] = @[
  @[],
  @[("amount", cbUint(100'u64)), ("to", cbText("alice"))],
  @[("amount", cbUint(100'u64)), ("to", cbText("bob"))],
  @[("k", cbArray(@[cbUint(1'u64), cbUint(2'u64), cbUint(3'u64)]))],
]

var allDistinct = true
for content in contents:
  var digestsHex: seq[string]
  var seen = initHashSet[string]()
  for d in domains:
    let hx = toHex(digest(hashInput(d, content)))
    digestsHex.add hx
    if hx in seen: allDistinct = false
    seen.incl hx
  # Emit the collection the oracle checks for distinctness.
  var arr = "["
  for i, hx in digestsHex:
    if i > 0: arr.add ", "
    arr.add "\"" & hx & "\""
  arr.add "]"
  echo "{\"digests\": ", arr, "}"

doAssert allDistinct, "two domains produced a colliding digest for identical content"
