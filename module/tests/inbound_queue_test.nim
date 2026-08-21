## InboundQueue mechanics — the foreign-thread seam's copy logic (the risky part).
## Thread-safety is by construction (lock + untraced alloc, no Nim GC in enqueue);
## this exercises the enqueue/drain round-trip, FIFO order, and empty payloads.
## Pure Nim: `nim r -d:release tests/inbound_queue_test.nim`.

import ../src/transport/inbound_queue

var q: InboundQueue
initInboundQueue(q)

q.enqueue(@[byte 1, 2, 3])
q.enqueue(@[byte 4, 5])
q.enqueue(@[byte 6])
let drained = q.drain()
doAssert drained.len == 3, "all enqueued messages drain"
doAssert drained[0] == @[byte 1, 2, 3] and drained[1] == @[byte 4, 5] and drained[2] == @[byte 6],
         "FIFO order preserved (oldest first)"
echo "1. enqueue/drain FIFO OK"

doAssert q.drain().len == 0, "a drained queue is empty"
echo "2. empty after drain OK"

q.enqueue(@[])
let d2 = q.drain()
doAssert d2.len == 1 and d2[0].len == 0, "empty payload round-trips"
echo "3. empty payload OK"

q.close()
echo "inbound_queue_test: all OK"
