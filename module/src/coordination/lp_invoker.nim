## The real Invoker: calls the target module over the `lp_*` C ABI, via the shared
## SDK's PluginProxy (dogfooding logos_sdk). Kept separate from invoker.nim so that
## the decision logic there stays headless-testable — this half resolves lp_* only
## at plugin link time. The target's capability policy is enforced by the lp_* layer:
## a call muster is not authorized to make comes back as an error, which executeInvoke
## treats as a refusal (the capability half of the gate).

import std/json
import logos_sdk/plugin
import ./invoker
import ./module_registry

type
  LpInvoker* = ref object of Invoker
    origin*: string        ## this module's name — the identity the target authorizes

proc newLpInvoker*(origin = "muster_module"): LpInvoker =
  LpInvoker(origin: origin)

method call*(inv: LpInvoker, targetModule, targetMethod, argsJson: string): InvokeOutcome =
  let p = newPluginProxy(targetModule, inv.origin)
  var args = newJArray()
  try:
    let parsed = parseJson(argsJson)
    if parsed.kind == JArray: args = parsed
  except CatchableError: discard
  let r = p.callSync(targetMethod, args)
  if r.ok:
    InvokeOutcome(ok: true, value: (if r.value != nil: $r.value else: ""))
  else:
    InvokeOutcome(ok: false, error: (if r.error != nil: $r.error else: "invoke failed"))

method methodsOf*(inv: LpInvoker, targetModule: string): JsonNode =
  ## The target's method descriptors over lp_get_methods (via the SDK proxy), for
  ## discovery. An unreachable/unloaded module yields an empty array, not a raise.
  try: newPluginProxy(targetModule, inv.origin).methodsOf()
  except CatchableError: newJArray()

proc lpModuleRecord*(origin = "muster_module", budgetMs = RegistryBudgetMs): ModuleRecordProbe =
  ## modules_state.module_record over lp_* (exo-dcc.10): the host's registry of module
  ## lifecycle state, asked before muster calls into a module. Bounded by `budgetMs` (in
  ## Basecamp it answers in milliseconds), never the lp default of 20 s: readiness is
  ## polled on the module's one thread, and a host without modules_state (the standalone
  ## runner) must cost little. The registry's own methods are not listed first —
  ## lp_get_methods takes no deadline — so a null is checked against muster itself
  ## (module_registry.selfChecked) and the host caches the answers (cachedRecords).
  (proc(name: string): ModuleRecordAnswer =
    let r = newPluginProxy("modules_state", origin).callSync("module_record", %*[name], cint(budgetMs))
    if not r.ok:
      return unanswered("modules_state did not answer: " & (if r.error != nil: $r.error else: "no error given"))
    parseModuleRecord(r.value))
