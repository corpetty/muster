## The host's module registry, as readiness reads it (exo-dcc.10).
##
## A module requirement is graded in three states — running, installed but not running,
## not installed — so the card can offer the right next step: install it (through
## Basecamp's Package Manager, on the person's confirmation), start it, or wait. Where a
## module stands is the host's to say: `modules_state.module_record(module) -> ? ModuleRecord`,
## the platform's read-only registry of module lifecycle state (bundled in Basecamp 0.3.x,
## always loaded there, answering in milliseconds). Its answer, as the contract has it and
## as Basecamp 0.3.2 was seen to give it:
##   * JSON null — the host does not know the module (never discovered, or pruned): NOT
##     INSTALLED. Null is an answer, never a failure;
##   * a record — graded on its `state` alone (path, version and dependencies are empty for
##     a module installed this session): unloaded (installed; nothing loads it but an app
##     that depends on it opening) | loading | loaded | ready (≈0.3–0.5 s after loaded) |
##     stopping | error (with a `reason`). Any state this client does not know is "not
##     loaded" (the registry's normative forward-compatibility rule), never an error.
## Only core modules are in it — a ui_qml package always reads null — so a requirement
## names a core module and `install` names the package to request.
##
## The registry is asked FIRST, and muster calls into a module (Invoker.methodsOf) only
## once the host reports it ready: over lp, a call to a module installed but not loaded
## blocks for the caller's whole deadline (20 s) before it fails, and lp_get_methods takes
## no deadline at all. Anything else from the registry — none (the standalone runner
## bundles no modules_state), a failed or timed-out call, a value that is not a record, a
## registry that does not know muster itself — is "cannot say": readiness then asks the
## module itself, as it did before the registry, and never grades it not installed.
##
## Readiness is polled — by the card and by the composer's kind list — on the module's one
## dispatch thread. So the host bounds each registry call (lp_invoker.lpModuleRecord, a
## short budget) and keeps every answer a few seconds per module name, and a registry that
## cannot be asked stays unasked for a minute (cachedRecords; the module's own methods,
## newCachedInvoker in invoker.nim). This half is pure: the lp call is the plugin's.

import std/[json, tables, times, monotimes]

type
  ModuleRecordAnswer* = object
    ## What the host's registry said about one module.
    answered*: bool   ## false = it could not be asked: no registry, a failed or timed-out call, an unreadable answer
    known*: bool      ## the host knows the module (a record came back); answered and not known = null = not installed
    state*: string    ## the record's lifecycle state, as the registry spells it
    reason*: string   ## the record's reason (why it is in `error`), "" when it carries none
    detail*: string   ## why it could not be asked (answered = false)

  ModuleRecordProbe* = proc(name: string): ModuleRecordAnswer {.gcsafe.}
    ## modules_state.module_record for one module — the host's closure, bounded and cached.

const
  RegistryWindow* = initDuration(seconds = 5)
    ## How long one answer about a module stands before the host asks again.
  RegistryDownWindow* = initDuration(seconds = 60)
    ## How long a registry that could not be asked stays unasked, about any module.
  RegistryBudgetMs* = 500
    ## One module_record call's budget: modules_state answers in milliseconds, and a host
    ## without it (the standalone runner) pays this once a RegistryDownWindow.

proc unanswered*(detail: string): ModuleRecordAnswer =
  ModuleRecordAnswer(answered: false, detail: detail)

proc parseModuleRecord*(v: JsonNode): ModuleRecordAnswer =
  ## module_record's value as it arrives over lp_*: null → not known (not installed); a
  ## record → its state and reason; a JSON value wrapped in a string is unwrapped first.
  ## "" — the old failure sentinel, which a call that raced its token push returns — and
  ## anything that is not a record are unreadable: cannot say, never "not installed". A
  ## value a host wraps — {"result": …}, logoscore's {"status": "ok", "result": …} — is
  ## unwrapped (a record has no `result` field).
  var j = v
  if j != nil and j.kind == JString:
    try: j = parseJson(j.getStr())
    except CatchableError: return unanswered("modules_state answered " & $v & ", not a module record")
  if j == nil: return unanswered("modules_state gave no answer")
  if j.kind == JObject and j.hasKey("result") and not j.hasKey("state"): j = j["result"]
  if j.kind == JNull: return ModuleRecordAnswer(answered: true, known: false)
  if j.kind == JObject and j.hasKey("state") and j["state"].kind == JString:
    return ModuleRecordAnswer(answered: true, known: true, state: j["state"].getStr(),
                              reason: j{"reason"}.getStr(""))
  unanswered("modules_state answered " & $j & ", not a module record")

proc selfChecked*(ask: ModuleRecordProbe, self: string): ModuleRecordProbe =
  ## `ask`, whose null counts as "not installed" only when the same registry knows `self`
  ## — this module, loaded since it is asking. An unknown method answers null on every
  ## transport, so a modules_state without module_record would otherwise read every module
  ## as not installed, and one the host has not fed knows nothing yet: either is "cannot
  ## say". Asked about `self` only on a null for another module; a record passes as it is.
  (proc(name: string): ModuleRecordAnswer =
    let a = ask(name)
    if a.answered and not a.known and name != self:
      let me = ask(self)
      if not (me.answered and me.known):
        return unanswered("modules_state does not know " & self & " itself: it cannot say what is installed")
    a)

proc cachedRecords*(ask: ModuleRecordProbe, window = RegistryWindow, downWindow = RegistryDownWindow,
                    now: proc(): MonoTime {.gcsafe.} = nil): ModuleRecordProbe =
  ## `ask`, kept `window` per module name. A registry that could not be asked (a no-answer
  ## or a raise) is not asked again, about any module, for `downWindow`: its no-answer
  ## stands for all of them. `now` is the clock (tests turn it); nil = the monotonic clock.
  let seen = newTable[string, tuple[at: MonoTime, answer: ModuleRecordAnswer]]()
  var down = (until: MonoTime(), answer: ModuleRecordAnswer())
  (proc(name: string): ModuleRecordAnswer =
    let t = (if now != nil: now() else: getMonoTime())
    if t < down.until: return down.answer
    if name in seen and t - seen[name].at < window: return seen[name].answer
    var a: ModuleRecordAnswer
    try: a = ask(name)
    except CatchableError as e: a = unanswered("modules_state call failed: " & e.msg)
    if a.answered: seen[name] = (t, a)
    else: down = (t + downWindow, a)
    a)
