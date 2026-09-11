## P-D3 — discovering the coordinatable actions a module offers, so the client can
## show "your modules let you do these things with others." Given a module's method
## descriptors (from lp_get_methods) and the invoke allowlist, present each candidate
## action: whether it is already allowlisted (executable now) or a candidate an
## operator could opt in.
##
## LIDL doesn't mark side-effects, so the signal is a NAME heuristic (get*/list*/… are
## reads) PLUS curation: an allowlisted method is coordinatable regardless of name,
## and a read-named method that is NOT allowlisted is pruned. Never a silent guess
## that a read is an action — the allowlist always overrides the heuristic.

import std/[json, strutils]
import ./invoker

const readPrefixes = ["get", "is", "has", "list", "available", "version", "metrics",
                      "collect", "read", "query", "info", "status", "count", "describe"]

proc isReadName*(name: string): bool =
  ## Conservative: does this method name read rather than DO something? The common
  ## query prefixes + a few known infra verbs. Curation overrides it either way.
  let n = name.toLowerAscii()
  for p in readPrefixes:
    if n.startsWith(p): return true
  false

type Action* = object
  module*, meth*, signature*: string
  params*: JsonNode      ## the method's parameter descriptors (for the compose card)
  allowed*: bool         ## on the invoke allowlist → executable now (vs a candidate)

proc discoverActions*(module: string, methodsJson: JsonNode, allow: Allowlist): seq[Action] =
  ## From a module's lp_get_methods array + the allowlist, the coordinatable actions.
  ## A method is included if it is allowlisted (curated in) OR does not look like a
  ## read; each carries `allowed` = executable-now.
  if methodsJson.isNil or methodsJson.kind != JArray: return
  for m in methodsJson:
    if m.kind != JObject: continue
    let name = m{"name"}.getStr()
    if name.len == 0: continue
    let (isAllowed, _) = allow.allows(module, name)
    if not isAllowed and isReadName(name): continue    # a read, not curated in → prune
    result.add Action(module: module, meth: name,
                      signature: m{"signature"}.getStr(),
                      params: (if m.hasKey("parameters"): m["parameters"] else: newJArray()),
                      allowed: isAllowed)

proc actionsJson*(actions: seq[Action]): JsonNode =
  ## Render-ready for the client: [{module, method, signature, params, allowed}].
  result = newJArray()
  for a in actions:
    result.add %*{"module": a.module, "method": a.meth, "signature": a.signature,
                  "params": a.params, "allowed": a.allowed}

proc discoverAcross*(inv: Invoker, modules: seq[string], allow: Allowlist): JsonNode =
  ## Query each candidate module's descriptors and collect its coordinatable actions.
  ## The candidate module set is configured (muster does not blind-scan every loaded
  ## module) — the allowlist's modules plus any operator-named extras.
  var all: seq[Action]
  for module in modules:
    all.add discoverActions(module, inv.methodsOf(module), allow)
  actionsJson(all)
