## Intents as a fold over the coordination log — where invariant 4
## (state = reduce(log)) becomes literal for the multi-party case.
##
## Each intent operation is a log event; `reduceIntents` replays them through the
## SAME lifecycle engine the single-instance path uses (`lifecycle.apply`), so two
## instances with the same event set compute identical intent states — no second
## state machine, no drift. The Safe driver verifies each contribution (recovers
## to an owner) before it counts toward the threshold, exactly as the hosted
## `approve` does; here that verification is part of the pure fold.
##
## Events (key/value on the coordination log):
##   propose : "intent/<id>/propose"            value = effect JSON {to,value,nonce}
##   sign    : "intent/<id>/sig/<contributor>"  value = 65-byte owner signature hex
##   submit  : "intent/<id>/submit"             value = "1"
## A contribution is keyed by contributor, so a duplicate signature from the same
## owner folds once (Safe dedups too).

import std/[json, tables, sets, strutils]
import ../log/log
import ../intents/lifecycle
import ../intents/materialization
import ../intents/signing_payload
import ../drivers/driver
import ../drivers/safe
import ../dcbor/dcbor
import ../hashing/keccak256
import ../crypto/secp256k1
export lifecycle.Intent, lifecycle.LifecycleState

proc effectFromJson*(effectJson: string): Effect =
  var fields: seq[(string, CborValue)]
  try:
    let j = parseJson(effectJson)
    if j.kind == JObject:
      if j.hasKey("to"): fields.add ("to", cbText(j["to"].getStr()))
      if j.hasKey("value"): fields.add ("value", cbUint(uint64(j["value"].getInt())))
      if j.hasKey("nonce"): fields.add ("nonce", cbUint(uint64(j["nonce"].getInt())))
  except CatchableError: discard
  Effect(schemaId: "muster.effect.transfer.v1", fields: fields)

proc hexToBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard

proc bytesHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# ── surface helpers (the hosted coordination methods are thin glue over these) ──

proc intentIdFor*(effectJson: string): string =
  ## A content-addressed intent id, so independent hosts derive the SAME id for the
  ## same effect without a round-trip to agree on one. First 8 bytes of
  ## keccak256(effect) — enough to key the intents in one conversation, and it makes
  ## re-proposing the same effect idempotent (same id, folds once).
  var b: seq[byte]
  for c in effectJson: b.add byte(c)
  bytesHex(keccak256(b)[0 ..< 8])

proc effectJsonOf*(events: seq[Event], intentId: string): string =
  ## The effect a proposal carried, recovered from the log — a contributor needs it
  ## to recompute the safeTxHash their signature must cover. "" if not proposed here.
  for e in events:
    if e.key == "intent/" & intentId & "/propose": return e.value
  ""

proc safeTxHashOf*(driver: SafeDriver, effectJson: string): array[32, byte] =
  let m = canonicalize(driver, effectFromJson(effectJson))
  for i in 0 ..< 32: result[i] = m.bytes[i]

proc contributorOf*(driver: SafeDriver, effectJson, signatureHex: string): string =
  ## The owner address (hex) that signed this intent's safeTxHash, or "" if the
  ## signature does not recover to a configured owner. A contribution is keyed by
  ## this, so a duplicate owner signature folds once and a non-owner never counts —
  ## the same verification the hosted approve() does, done before we publish.
  let h = safeTxHashOf(driver, effectJson)
  var sig: Signature65
  let sb = hexToBytes(signatureHex)
  for i in 0 ..< min(65, sb.len): sig[i] = sb[i]
  if not recoversToOwner(h, sig, driver.owners): return ""
  bytesHex(ecrecover(h, sig))

# ── event constructors (what a participant publishes) ─────────────────────────

proc proposeEvent*(intentId, effectJson: string): Event =
  Event(key: "intent/" & intentId & "/propose", value: effectJson)

proc contributeEvent*(intentId, contributor, signatureHex: string,
                      parents: seq[EventId] = @[]): Event =
  Event(parents: parents, key: "intent/" & intentId & "/sig/" & contributor,
        value: signatureHex)

proc submitEvent*(intentId: string, parents: seq[EventId] = @[]): Event =
  Event(parents: parents, key: "intent/" & intentId & "/submit", value: "1")

# ── the fold: intent lifecycle = reduce(log) ──────────────────────────────────

proc reduceIntents*(events: seq[Event], driver: SafeDriver): Table[string, Intent] =
  ## Deterministic: proposes, then contributions, then submits, each in canonical
  ## order — so the result is a pure function of the event SET, independent of the
  ## order events arrived or were duplicated (invariant 4, R-2/R-3). Ordering is by
  ## pass rather than by causal parents, so it holds even when a contribution
  ## arrives before its propose.
  result = initTable[string, Intent]()
  var hashes = initTable[string, array[32, byte]]()
  var seenSig = initHashSet[string]()   # "<id>/<contributor>" — one signature per owner
  var now: uint64 = 0
  let ordered = canonicalOrder(events)

  proc opOf(e: Event): (string, string, string) =
    let p = e.key.split('/')
    if p.len >= 3 and p[0] == "intent":
      (p[1], p[2], (if p.len >= 4: p[3] else: ""))
    else: ("", "", "")

  for e in ordered:                                    # pass 1 — proposes
    let (id, op, _) = opOf(e)
    if op != "propose" or id.len == 0 or id in result: continue
    inc now
    let effect = effectFromJson(e.value)
    let ctx = SigningContext(environment: "", account: "coordinated", slot: "0",
                             expiry: high(uint64))
    var it = newIntent(driver, effect, ctx)   # canonicalize dispatches to the driver (safeTxHash + pendingHash)
    var h: array[32, byte]
    for i in 0 ..< 32: h[i] = it.materialization.bytes[i]
    hashes[id] = h
    it.apply(driver, IntentEvent(kind: iePropose, now: now))
    result[id] = it

  for e in ordered:                                    # pass 2 — contributions
    let (id, op, who) = opOf(e)
    if op != "sig" or id notin result: continue
    let dedup = id & "/" & who
    if dedup in seenSig: continue
    seenSig.incl dedup
    inc now
    driver.pendingHash = hashes[id]                    # verify against THIS intent's hash
    var it = result[id]
    it.apply(driver, IntentEvent(kind: ieContribute, now: now,
                                 contribution: Contribution(bytes: hexToBytes(e.value))))
    result[id] = it

  for e in ordered:                                    # pass 3 — submits
    let (id, op, _) = opOf(e)
    if op != "submit" or id notin result: continue
    inc now
    var it = result[id]
    it.apply(driver, IntentEvent(kind: ieSubmit, now: now))
    result[id] = it

proc intentState*(events: seq[Event], driver: SafeDriver, intentId: string): string =
  ## The lifecycle state of one intent as a string (draft/proposed/collecting/
  ## executable/…), or "unknown".
  let intents = reduceIntents(events, driver)
  if intentId in intents: $intents[intentId].state else: "unknown"
