## P-D2 — the generic execution path for invoke intents, headless.
##
## Two parts:
##   A. the executeInvoke GATE (allowlist + capability) in isolation, with a
##      LocalInvoker standing in for the target module — never a mock of Driver or
##      Transport, just an in-process Invoker (the Local/Delivery split).
##   B. end to end: an invoke intent folds to executable through the SAME
##      coordination fold the room uses (reduce(log), generic invoke driver), then
##      the core executes it — proving fold → executable → execute → final, and that
##      the handler received exactly the args the effect carried.
##
## Link flags (curve25519 + dcbor + secp for registry): see tests/README.md.

import std/[json, strutils]
import ../src/coordination/invoker
import ../src/coordination/intents
import ../src/drivers/invoke
import ../src/drivers/driver
import ../src/intents/materialization
import ../src/crypto/curve25519

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc okHandler(argsJson: string): InvokeOutcome {.gcsafe.} =
  InvokeOutcome(ok: true, value: "\"req-1\"")

# ── A. the gate: allowlist AND capability ──────────────────────────────────────
block:
  let allow = @[AllowEntry(module: "delivery_module", meth: "send", finalityEvent: "messageSent")]

  # allowlisted + capability granted (a handler exists) → executed, args delivered
  let inv = newLocalInvoker()
  inv.register("delivery_module", "send", okHandler)
  let r1 = executeInvoke(inv, allow, "delivery_module", "send", "[\"/topic\",\"hi\"]")
  doAssert r1.executed and r1.state == "executed", "allowlisted+capable must execute: " & r1.reason
  doAssert inv.lastArgs == "[\"/topic\",\"hi\"]", "the target received the exact args"
  doAssert r1.finalityEvent == "messageSent", "finality event carried from the allowlist"

  # NOT allowlisted → refused WITHOUT calling (the room agreed, the core still won't)
  let inv2 = newLocalInvoker()
  inv2.register("delivery_module", "send", okHandler)
  let r2 = executeInvoke(inv2, allow, "delivery_module", "stop", "[]")
  doAssert (not r2.executed) and r2.reason.startsWith("not-allowlisted"),
           "an un-allowlisted action is refused: " & r2.reason
  doAssert inv2.lastMethod == "", "a refused action is never invoked"

  # allowlisted but capability-denied (no handler = the lp_* layer would reject) →
  # refused honestly, never a false success
  let allow2 = @[AllowEntry(module: "vault_module", meth: "withdraw")]
  let r3 = executeInvoke(inv, allow2, "vault_module", "withdraw", "[100]")
  doAssert (not r3.executed) and r3.reason.contains("capability"),
           "a capability-denied call is a refusal, not a success: " & r3.reason
  echo "A. execute gate (allowlist AND capability) OK"

# ── B. end to end: fold an invoke intent to executable, then execute it ─────────
block:
  proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
  let member = encFromSeed(seed(21))
  let drv = newInvokeDriver(@[member.identity().ed], k = 1)
  let driverFor: DriverFor = proc(kind: string): Driver =
    (if kind == "invoke": Driver(newInvokeDriver(@[member.identity().ed], 1))
     else: Driver(newStubDriver()))

  # the room proposes: call delivery_module.send("/room","hello")
  let effectJson = """{"effect":"invoke","module":"delivery_module","method":"send","args":["/room","hello"]}"""
  let id = intentIdFor(effectJson, "invoke")
  # one roster member endorses over the re-derived materialization (invariant 1 bytes)
  let mat = canonicalize(drv, effectFromJson(effectJson))
  let sig = edSign(member, mat.bytes)
  let sigHex = toHex(sig)
  let who = contributorOf(drv, effectJson, sigHex)
  doAssert who.len > 0, "the endorsement identifies a roster member"

  var events = @[
    policyDeclEvent(id, "invoke"),
    proposeEvent(id, effectJson),
    contributeEvent(id, who, sigHex)]
  doAssert intentState(events, driverFor, id) == "executable",
           "one endorsement (k=1) folds the invoke intent to executable"

  # the core executes it: re-read the effect from the log, gate + invoke via the
  # Invoker (here Local), then fold the room forward with a final event.
  let ej = effectJsonOf(events, id)
  let je = parseJson(ej)
  let inv = newLocalInvoker()
  inv.register("delivery_module", "send", okHandler)
  let allow = @[AllowEntry(module: "delivery_module", meth: "send")]
  let ex = executeInvoke(inv, allow, je["module"].getStr(), je["method"].getStr(), $je["args"])
  doAssert ex.executed, "the executable invoke intent runs: " & ex.reason
  doAssert inv.lastArgs == """["/room","hello"]""",
           "the module received the folded args, got: " & inv.lastArgs

  # the core folds the room forward: submit (executed) → final (completion observed),
  # exactly as coordinate_submit does for Safe.
  events.add submitEvent(id)
  doAssert intentState(events, driverFor, id) == "submitted",
           "the executed invoke intent folds to submitted"
  events.add finalEvent(id)
  doAssert intentState(events, driverFor, id) == "final",
           "after finality the fold converges to final"
  echo "B. fold → executable → execute (delivery_module.send) → submitted → final OK"

echo "invoke_execute_test: all OK"
