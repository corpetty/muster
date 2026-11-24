## A test driver that settles in parts and is NOT the split, so a test proves the
## core's generic rule (exo-a90.2). The effect is a statement whose text is
## "parts=<a>,<b>,…;to=<counterparty>". A contribution is the contributor's name as
## bytes and counts iff that name is one of the parts. Part <p> is settled by <p> and
## confirmed by the counterparty. Its manifest declares what a payment shows the chain.
## Used by flow_test (exo-c7c) and room_graph_test (exo-dde).

import std/[json, strutils, sequtils]
import ../../src/dcbor/dcbor
import ../../src/intents/materialization
import ../../src/intents/disclosure
import ../../src/drivers/driver
import ../../src/drivers/manifest
import ../../src/drivers/profile
import ../../src/log/log
import ../../src/coordination/intents

type PartsDriver* = ref object of Driver
  pending: seq[byte]

proc spec(e: Effect): tuple[parts: seq[string], to: string] =
  for piece in fieldText(e, "text").split(';'):
    let kv = piece.split('=')
    if kv.len != 2: continue
    if kv[0] == "parts": result.parts = kv[1].split(',').filterIt(it.len > 0)
    elif kv[0] == "to": result.to = kv[1]

proc specOfBytes(m: seq[byte]): tuple[parts: seq[string], to: string] =
  try:
    let v = decode(m)
    for (k, x) in v.arr[2].pairs:
      if k.t == "text": return spec(Effect(fields: @[("text", x)]))
  except CatchableError: discard

method describe*(d: PartsDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "muster.test.parts.v1", finality: finExternal, threshold: 1)
method describeFor*(d: PartsDriver, e: Effect): DriverDescriptor =
  result = d.describe(); result.threshold = max(1, spec(e).parts.len)
method expectMaterialization*(d: PartsDriver, m: Materialization) = d.pending = m.bytes
proc nameOf(c: Contribution): string = (for b in c.bytes: result.add char(b))
method verifyContribution*(d: PartsDriver, c: Contribution, round: int): bool = nameOf(c) in specOfBytes(d.pending).parts
method identifyContributor*(d: PartsDriver, m: Materialization, c: Contribution): string =
  (if nameOf(c) in specOfBytes(m.bytes).parts: nameOf(c) else: "")
method settlementParts*(d: PartsDriver, e: Effect): seq[string] = spec(e).parts
method partAuthor*(d: PartsDriver, e: Effect, part, step: string): string =
  let s = spec(e)
  if part notin s.parts: return ""
  case step
  of "settled": part
  of "confirmed": s.to
  else: ""
method profile*(d: PartsDriver): FamilyProfile =
  ## An each-locus family whose chain binds each party's signature itself, as evm.split's
  ## does (binding explicit). Since exo-af5 a driver with no declared profile is taken as
  ## room-bound, where a contribution counts only with an attestation over P; this
  ## driver's "signature" is the contributor's name, so it declares the chain-bound shape
  ## it always stood for — what its tests prove is the parts seam, not attestation.
  FamilyProfile(declared: true, family: "test.parts", settlement: "test",
    locus: loEach, scheme: scOwnTransaction, commits: cmContent, binding: bdExplicit,
    rounds: 1, k: 1, bypassesKnown: true)
method manifest*(d: PartsDriver, e: Effect): ActionManifest =
  ActionManifest(declared: true, agreement: d.describeFor(e),
    discloses: @[row("payer", obChainObserver), row("amount", obChainObserver), row("signed-tx", obRpcProvider)])

proc partsEffect*(parts: openArray[string], to: string): string =
  $(%*{"effect": "statement", "text": "parts=" & parts.join(",") & ";to=" & to})

proc hexName*(s: string): string =
  ## the contribution a PartsDriver counts: the contributor's name, as hex
  const d = "0123456789abcdef"
  for c in s: (result.add d[int(byte(c) shr 4)]; result.add d[int(byte(c) and 0x0F)])

proc chain*(evs: seq[Event]): seq[Event] =
  ## each event's parent is the one before it, so canonical order is the listed order
  ## (this re-parents events, which changes their ids: look them up by key)
  for e in evs:
    var x = e
    if result.len > 0: x.parents = @[eventId(result[^1])]
    result.add x
