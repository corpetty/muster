## The execution seam for the generic invoke driver (P-D2 · design:
## docs/design/driver-derivation.md §P-D2).
##
## An invoke intent that reaches *executable* (the room endorsed it k-of-n) is
## EXECUTED by the core: it calls the module method the effect names. This seam
## abstracts that call so the decision + finality logic is testable in-process with
## a LocalInvoker, and the real path uses LpInvoker over the `lp_*` C ABI — the same
## Local/Delivery split the Transport seam uses, never a mock.
##
## The gate is **allowlist + capability** (the chosen model):
##   1. ALLOWLIST — only (module, method) pairs the room's config allows are executed;
##      an un-allowlisted action reaches executable (the room agreed) but the core
##      REFUSES to invoke it. Start closed, open deliberately.
##   2. CAPABILITY — the call must also succeed under the TARGET module's own
##      capability policy, which the `lp_*` layer enforces: a capability-denied call
##      comes back as an error, surfaced honestly as a failed execution — never a
##      false "done". (Invariant 3: the driver never invokes; the core does.)

import std/[json, tables]

type
  InvokeOutcome* = object
    ok*: bool          ## did the call succeed (capability granted AND the method ran)?
    value*: string     ## the method's result JSON on success
    error*: string     ## the target's error (e.g. capability-denied) on failure

  Invoker* = ref object of RootObj

method call*(inv: Invoker, targetModule, targetMethod, argsJson: string): InvokeOutcome
    {.base, gcsafe.} =
  raise newException(CatchableError, "Invoker.call is abstract")

# ── the allowlist (config) ─────────────────────────────────────────────────────

type
  AllowEntry* = object
    module*, meth*: string
    finalityEvent*: string   ## "" → immediate; else the completion event to await (P-D2 finality)
  Allowlist* = seq[AllowEntry]

proc allows*(a: Allowlist, module, meth: string): (bool, AllowEntry) =
  for e in a:
    if e.module == module and e.meth == meth: return (true, e)
  (false, AllowEntry())

proc parseAllowlist*(j: JsonNode): Allowlist =
  ## From config JSON: [{"module":"x","method":"y","finalityEvent":"..."}].
  if j.isNil or j.kind != JArray: return
  for e in j:
    if e.kind == JObject and e.hasKey("module") and e.hasKey("method"):
      result.add AllowEntry(module: e["module"].getStr(), meth: e["method"].getStr(),
                            finalityEvent: e{"finalityEvent"}.getStr(""))

# ── the execute decision (the testable core) ───────────────────────────────────

type
  ExecOutcome* = object
    executed*: bool     ## did the method actually run (allowlisted AND capability-granted)?
    state*: string      ## "executed" | "refused"
    reason*: string     ## why it was refused, or the method's result on success
    finalityEvent*: string  ## the event to await for finality ("" = immediate)

proc executeInvoke*(inv: Invoker, allow: Allowlist,
                    targetModule, targetMethod, argsJson: string): ExecOutcome =
  ## The gate + the call. ALLOWLIST first (never call an un-allowlisted action), then
  ## CAPABILITY (the call must succeed under the target's own policy; a rejection is a
  ## refusal, not a success). This is the one place both gates are applied.
  let (allowed, entry) = allow.allows(targetModule, targetMethod)
  if not allowed:
    return ExecOutcome(executed: false, state: "refused",
                       reason: "not-allowlisted: " & targetModule & "." & targetMethod)
  let outcome = inv.call(targetModule, targetMethod, argsJson)
  if not outcome.ok:
    return ExecOutcome(executed: false, state: "refused",
                       reason: "invoke-rejected (capability or method error): " & outcome.error)
  ExecOutcome(executed: true, state: "executed", reason: outcome.value,
              finalityEvent: entry.finalityEvent)

# ── LocalInvoker: in-process routing, for tests + single-instance coordination ──

type
  InvokeHandler* = proc(argsJson: string): InvokeOutcome {.gcsafe.}
  LocalInvoker* = ref object of Invoker
    handlers: Table[string, InvokeHandler]   ## "module.method" → handler
    lastModule*, lastMethod*, lastArgs*: string  ## the last call, for tests to inspect

proc newLocalInvoker*(): LocalInvoker =
  LocalInvoker(handlers: initTable[string, InvokeHandler]())

proc register*(inv: LocalInvoker, targetModule, targetMethod: string, h: InvokeHandler) =
  inv.handlers[targetModule & "." & targetMethod] = h

method call*(inv: LocalInvoker, targetModule, targetMethod, argsJson: string): InvokeOutcome =
  ## A registered handler stands in for the target module. NO registered handler
  ## models a capability-denied / not-loaded target — the call fails honestly, so a
  ## test exercises the capability half of the gate exactly as the lp_* layer would.
  ## The call is recorded (lastModule/Method/Args) so a test can assert what the
  ## target received without a closure capturing global state.
  inv.lastModule = targetModule
  inv.lastMethod = targetMethod
  inv.lastArgs = argsJson
  let key = targetModule & "." & targetMethod
  if key in inv.handlers: inv.handlers[key](argsJson)
  else: InvokeOutcome(ok: false, error: "capability-denied / not loaded: " & key)
