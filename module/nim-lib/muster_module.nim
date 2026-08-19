## Muster module impl — the hosted coordination surface.
##
## Includes the generated surface (muster_gen.nim, from muster.lidl) and defines
## the author methods it forwards to, wiring propose/approve/status to the intent
## lifecycle engine over the driver interface. The `.lgx` this builds into loads in
## logoscore and drives a full lifecycle (draft → proposed → collecting →
## executable) through the module's own dispatch — no external crypto/web3 deps in
## this surface (the stub driver stands in for a real Safe driver, which needs
## secp256k1 wired through the flake).

include muster_gen

import std/[json, tables, strutils]
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/intents/materialization
import ../src/intents/signing_payload
import ../src/intents/lifecycle

# Module-global coordination state. In the real client this is reduce(log); here
# it is in-memory for the hosted lifecycle demo.
var gIntents = initTable[string, Intent]()
var gDriver: Driver = newStubDriver(rounds = 1, threshold = 2)   # a 2-of-3 shape
var gCounter = 0
var gNow: uint64 = 0

proc musterHealth(): string =
  ## Liveness probe.
  "ok"

proc musterPropose(effectJson: string): string =
  ## Create an intent from an effect (JSON object of typed fields), advance it to
  ## proposed, and return its id.
  var fields: seq[(string, CborValue)]
  try:
    let j = parseJson(effectJson)
    if j.kind == JObject:
      for k, v in j:
        case v.kind
        of JInt: fields.add (k, cbInt(v.getInt()))
        of JString: fields.add (k, cbText(v.getStr()))
        of JBool: fields.add (k, cbBool(v.getBool()))
        else: discard
  except CatchableError: discard
  let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: fields)
  let ctx = SigningContext(environment: "hosted", account: "acct", slot: "0",
                           expiry: high(uint64))
  inc gCounter
  let id = "intent-" & $gCounter
  var it = newIntent(gDriver, effect, ctx)
  it.apply(gDriver, IntentEvent(kind: iePropose, now: gNow))
  gIntents[id] = it
  id

proc musterApprove(intentId: string, contributionHex: string): string =
  ## Add a contribution (opaque to the core) to an intent's collection; return the
  ## new lifecycle state.
  if intentId notin gIntents: return "unknown-intent"
  var bytes: seq[byte]
  var h = contributionHex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2..^1]
  for i in 0 ..< h.len div 2:
    try: bytes.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard
  if bytes.len == 0: bytes = @[1'u8]
  var it = gIntents[intentId]
  inc gNow
  it.apply(gDriver, IntentEvent(kind: ieContribute, now: gNow,
                                contribution: Contribution(bytes: bytes)))
  gIntents[intentId] = it
  $it.state

proc musterStatus(intentId: string): string =
  ## Return an intent's current lifecycle state.
  if intentId notin gIntents: return "unknown-intent"
  $gIntents[intentId].state
