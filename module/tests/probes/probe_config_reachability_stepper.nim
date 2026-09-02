## derived-exo-8e7 s3/c3: the re-derive-or-refuse check cannot be bypassed by any
## configuration flag, plugin, or user preference — it is unconditional core
## behavior. A config surface that quietly suppressed the check anywhere in the
## reachable space would surface here as a counterexample.
##
## STEPPER (exo-dbc): the oracle BFS-walks the reachable config graph, so this
## probe is the TRANSITION RELATION, not an enumeration. Given a state as its
## final argv it prints that state's successors — the configs one single toggle
## away — each carrying `mismatch_refused` actually measured for that config.
## The runner asserts the invariant over every state it reaches from the spec's
## `initial` ({"config_id": "default", "mismatch_refused": true}).

import ../../src/dcbor/dcbor
import ../../src/drivers/driver
import ../../src/intents/materialization
import std/strutils
import ./oracle_emit

const
  Skips = [false, true]
  Prefs = ["", "auto-sign", "trust-driver"]
  PluginSets = @[@[], @["balance"], @["balance", "decision"], @["evil-bypass"]]

type ConfigPoint = object
  skip: bool
  prefIdx: int
  pluginIdx: int

proc configId(c: ConfigPoint): string =
  ## The state's identity, round-trippable so the BFS can hand it back to us.
  "skip=" & $c.skip & ",pref=" & Prefs[c.prefIdx] & ",plugins=" & $c.pluginIdx

proc parseConfigId(id: string): ConfigPoint =
  ## `initial`'s "default" is the origin of the space; anything else is one of
  ## our own emitted ids. An unparseable id is a hard error rather than a silent
  ## fallback — it would otherwise shrink the explored space without saying so.
  if id == "default": return ConfigPoint(skip: false, prefIdx: 0, pluginIdx: 0)
  var c = ConfigPoint()
  for part in id.split(','):
    let kv = part.split('=', 1)
    doAssert kv.len == 2, "malformed config_id: " & id
    case kv[0]
    of "skip": c.skip = kv[1] == "true"
    of "pref":
      let i = Prefs.find(kv[1])
      doAssert i >= 0, "unknown pref in config_id: " & id
      c.prefIdx = i
    of "plugins":
      c.pluginIdx = parseInt(kv[1])
      doAssert c.pluginIdx in 0 ..< PluginSets.len, "plugin index out of range: " & id
    else: doAssert false, "unknown key in config_id: " & id
  c

proc mismatchRefused(c: ConfigPoint): bool =
  ## Measure the invariant at this config: a materialization that does NOT match
  ## the effect's derivation must be refused, whatever the config says.
  let drv = newStubDriver()
  let e = Effect(schemaId: "muster.effect.transfer.v1",
                 fields: @[("amount", cbUint(100'u64)), ("to", cbText("alice"))])
  var mismatched = canonicalize(drv, e)
  mismatched.bytes.add 0xAA'u8
  let cfg = Config(skipReviewRequested: c.skip,
                   plugins: PluginSets[c.pluginIdx],
                   userPreference: Prefs[c.prefIdx])
  signProposal(cfg, drv, e, mismatched) == soRefused

proc state(c: ConfigPoint): JsonNode =
  %*{"config_id": configId(c), "mismatch_refused": mismatchRefused(c)}

proc successors(c: ConfigPoint): seq[JsonNode] =
  ## One single toggle along each dimension. The graph is undirected and fully
  ## connected over the product space, so BFS from `default` reaches every
  ## config — the exhaustiveness the model_check level claims.
  result.add state(ConfigPoint(skip: not c.skip, prefIdx: c.prefIdx, pluginIdx: c.pluginIdx))
  for i in 0 ..< Prefs.len:
    if i != c.prefIdx:
      result.add state(ConfigPoint(skip: c.skip, prefIdx: i, pluginIdx: c.pluginIdx))
  for i in 0 ..< PluginSets.len:
    if i != c.pluginIdx:
      result.add state(ConfigPoint(skip: c.skip, prefIdx: c.prefIdx, pluginIdx: i))

let arg = oracleStateArg()
let here =
  if arg == nil or not arg.hasKey("config_id"): ConfigPoint(skip: false, prefIdx: 0, pluginIdx: 0)
  else: parseConfigId(arg["config_id"].getStr)

emitSuccessors(successors(here))

# Run by hand (no argv) this still fails loudly if any reachable config bypasses
# the check — the probe stays a real test independent of the grader.
if arg == nil:
  for skip in Skips:
    for pi in 0 ..< Prefs.len:
      for gi in 0 ..< PluginSets.len:
        doAssert mismatchRefused(ConfigPoint(skip: skip, prefIdx: pi, pluginIdx: gi)),
          "a config value bypassed the unconditional materialization check"
