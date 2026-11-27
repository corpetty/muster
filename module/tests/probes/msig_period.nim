## When a test's spend under a lez-msig spending limit may start (exo-5ed). Settlement refuses
## a Spend within `SpendMarginMs` of its period's end, and a test that spends, then checks what
## the period has left, needs the whole step inside one period. A test asks this how long to
## wait first, so it never depends on the time of day.

proc spendWaitMs*(nowMs, periodMs, needMs: uint64): uint64 =
  ## How long to wait so that at least `needMs` of the current period remain: 0 when they do
  ## now, else until a second into the next period. `needMs` must leave that second spare.
  doAssert periodMs > 0 and needMs + 1_000 <= periodMs, "the step does not fit in one period"
  let left = periodMs - nowMs mod periodMs
  if left >= needMs: 0'u64 else: left + 1_000
