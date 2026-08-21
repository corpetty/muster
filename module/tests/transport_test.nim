## Transport interface + LocalTransport (P3, F-15). Two instances on one network
## exchange live; an offline instance catches up from the store; ingest is
## idempotent over store duplicates (R-2/R-4); content addresses are deterministic.
## Pure Nim — `nim r -d:release tests/transport_test.nim`.
##
## The body is a proc so the subscribe handlers capture locals, not globals — a
## {.gcsafe.} handler (which the real delivery-backed transport needs) may not
## touch module-level GC'd state.

import std/strutils
import ../src/transport/transport

proc main() =
  let net = newLocalNetwork()
  let alice = newLocalTransport(net)
  let bob = newLocalTransport(net)

  const topic = "/muster/1/conversation-xyz/proto"

  # ── 1. live exchange: alice publishes, bob (subscribed) receives ────────────
  var bobGot: seq[IncomingMessage]
  bob.subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} = bobGot.add m)

  let payload = @[byte 1, 2, 3, 4]
  let h1 = alice.publish(topic, payload)
  doAssert bobGot.len == 1, "bob should receive the live message"
  doAssert bobGot[0].payload == payload, "payload must arrive intact (bytes opaque to transport)"
  doAssert bobGot[0].messageHash == h1, "the receipt hash must match the delivered message hash"
  doAssert bobGot[0].contentTopic == topic
  echo "1. live exchange OK"

  # ── 2. content address is deterministic and topic/payload separated ─────────
  doAssert messageHashOf(topic, payload) == h1, "same (topic, payload) -> same hash"
  doAssert messageHashOf(topic, payload) != messageHashOf(topic, @[byte 1, 2, 3, 5]),
           "different payload -> different hash"
  doAssert messageHashOf(topic, payload) != messageHashOf(topic & "x", payload),
           "different topic -> different hash (domain separated)"
  doAssert h1.startsWith("0x") and h1.len == 66, "content address is a 32-byte hex digest"
  echo "2. deterministic content address OK"

  # ── 3. offline catchup: carol joins after the fact, reads from the store ────
  let carol = newLocalTransport(net)
  discard alice.publish(topic, @[byte 9, 9, 9])         # a second message while carol is away
  let history = carol.storeQuery(topic)
  doAssert history.len == 2, "carol catches up to both messages from the store"
  doAssert history[0].payload == payload and history[1].payload == @[byte 9, 9, 9],
           "store returns messages oldest first"
  echo "3. offline catchup OK"

  # ── 4. idempotent ingest: a re-published (duplicated) message stores once ───
  let hDup = alice.publish(topic, payload)              # identical bytes to message 1
  doAssert hDup == h1, "identical bytes -> identical content address"
  doAssert carol.storeQuery(topic).len == 2, "a duplicate must not grow the store (R-2/R-4)"
  echo "4. idempotent ingest OK"

  # ── 5. isolation: a different topic is a different conversation ─────────────
  doAssert carol.storeQuery("/muster/1/other/proto").len == 0,
           "an unrelated topic carries nothing"
  bobGot.setLen 0
  discard alice.publish("/muster/1/other/proto", @[byte 7])
  doAssert bobGot.len == 0, "bob is not subscribed to the other topic"
  echo "5. topic isolation OK"

  echo "transport_test: all OK"

main()
