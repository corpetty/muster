## Driver conformance suite (invariant 6 / spec derived-exo-2dc).
##
## Any Driver, together with the driver-generic Collection core, must satisfy
## these properties — so a new driver (different rounds / membership / finality)
## drops in with NO core change. `checkConformance` returns a list of failure
## descriptions (empty seq == conformant); the conformance tests run it against
## every driver, and the working agreement is: never merge with it red.
##
## The routing properties are checked through a StubDriver that MIRRORS the target
## driver's descriptor, because a real driver's verifyContribution may require
## valid crypto to accept. That isolates exactly what conformance owns — the
## CORE's descriptor-driven, byte-independent routing — from what a driver's own
## tests own (that its verify() accepts the right bytes). What we DO demand of the
## real driver directly: a well-formed, stable describe(), and a verifyContribution
## that is TOTAL — it returns a bool for any bytes, never raising or aborting (the
## property whose violation was the recid-abort DoS).

import ./driver

type ConformanceFailure* = string

proc checkConformance*(driver: Driver,
                       malformed: seq[Contribution] = @[]): seq[ConformanceFailure] =
  ## Property battery over `driver` + the Collection core. `malformed` supplies
  ## extra driver-specific hostile inputs verifyContribution must survive; the
  ## defaults cover the generic shapes.
  var failures: seq[ConformanceFailure] = @[]
  template fail(msg: string) = failures.add msg

  # ── P1: describe() is well-formed and STABLE (the core snapshots it once) ──
  let d0 = driver.describe()
  if driver.describe() != d0:
    fail("describe() is not stable across calls")
  if d0.rounds < 1: fail("describe().rounds must be >= 1, got " & $d0.rounds)
  if d0.threshold < 1: fail("describe().threshold must be >= 1, got " & $d0.threshold)
  if d0.serializationDomain.len == 0:
    fail("describe().serializationDomain must be non-empty")

  # ── P2: verifyContribution is TOTAL — a bool for any bytes, never fatal ──
  var probes = @[
    Contribution(bytes: @[]),               # empty
    Contribution(bytes: @[0'u8]),           # 1 byte
    Contribution(bytes: newSeq[byte](64)),  # one short of a 65-byte sig
    Contribution(bytes: newSeq[byte](65)),  # all-zero 65
    Contribution(bytes: newSeq[byte](200)), # over-long
  ]
  var junk65 = newSeq[byte](65)             # the exact recid-abort trigger (v = 0x11)
  for i in 0 ..< 65: junk65[i] = 0x11'u8
  probes.add Contribution(bytes: junk65)
  for c in malformed: probes.add c
  for c in probes:
    try:
      discard driver.verifyContribution(c, 1)
    except CatchableError as e:
      fail("verifyContribution raised on a " & $c.bytes.len &
           "-byte contribution: " & e.msg)

  # ── P3: core routing is DESCRIPTOR-DRIVEN and byte-independent ──
  # Drive acceptance deterministically via a stub mirroring d0; completion must be
  # a pure function of (descriptor, accept-count), independent of the bytes.
  block:
    let acc = newStubDriver(rounds = d0.rounds, threshold = d0.threshold,
      domain = d0.serializationDomain, membership = d0.membership,
      finality = d0.finality, verifyResult = true)
    var col = startCollection(acc)
    if col.roundCount != d0.rounds: fail("Collection.roundCount not sourced from describe()")
    if col.membershipDispatch != d0.membership: fail("membership not sourced from describe()")
    if col.finalityHandling != d0.finality: fail("finality not sourced from describe()")
    let need = d0.threshold * d0.rounds
    for i in 1 .. need:
      if col.complete: fail("completed early at " & $i & " of " & $need)
      col.submit(acc, Contribution(bytes: @[byte(i), byte(i * 7 + 1)]))  # varying bytes
    if not col.complete: fail("did not complete after threshold*rounds=" & $need)
    col.submit(acc, Contribution(bytes: @[9'u8]))   # inert once complete
    if not col.complete: fail("completion regressed after an extra submit")

  # ── P4: rejected contributions never advance ──
  block:
    let rej = newStubDriver(rounds = d0.rounds, threshold = d0.threshold,
      domain = d0.serializationDomain, membership = d0.membership,
      finality = d0.finality, verifyResult = false)
    var col = startCollection(rej)
    for i in 1 .. (d0.threshold * d0.rounds + 5):
      col.submit(rej, Contribution(bytes: @[byte(i)]))
    if col.complete: fail("collection completed on all-rejected contributions")

  # ── P5: exactly one round advances per threshold reached ──
  block:
    let acc = newStubDriver(rounds = d0.rounds, threshold = d0.threshold,
      domain = d0.serializationDomain, membership = d0.membership,
      finality = d0.finality, verifyResult = true)
    var col = startCollection(acc)
    for r in 1 .. d0.rounds:
      if col.round != r: fail("expected round " & $r & ", got " & $col.round)
      for k in 1 .. d0.threshold:
        col.submit(acc, Contribution(bytes: @[byte(r), byte(k)]))
    if not col.complete: fail("multi-round collection did not complete")

  failures
