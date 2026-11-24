## A module action's card shows the call it endorses, arguments and all (exo-3b3.18, audit
## P4-06). The arguments are in the signed bytes; the card read "an action: m.f(2 args)", so a
## member endorsed a call without seeing what it would be called with. effectSummary now
## names every argument, decoded, in order, and the line reads as the exact call.
## Needs the effect_summary closure (stint; see tests/README.md).

import std/strutils
import ../src/coordination/effect_summary

let lbl = proc(w: string): string = w

block:
  let s = effectSummary("""{"effect":"invoke","module":"vault_module","method":"withdraw","args":["0xAbC0000000000000000000000000000000000001",250,{"memo":"rent"}]}""", lbl)
  doAssert s.kind == "action" and s.to == "vault_module.withdraw", $s
  doAssert s.args == @["\"0xAbC0000000000000000000000000000000000001\"", "250", """{"memo":"rent"}"""], $s.args
  doAssert s.text == """an action: vault_module.withdraw("0xAbC0000000000000000000000000000000000001", 250, {"memo":"rent"})""", s.text
  echo "1. every argument shown, decoded, in order, in the exact call OK"

block:
  # args carried as their JSON text (the shape the propose path stores) read the same
  let s = effectSummary("""{"effect":"invoke","module":"m","method":"f","args":"[1,\"two\"]"}""", lbl)
  doAssert s.args == @["1", "\"two\""] and s.text == """an action: m.f(1, "two")""", s.text
  let none = effectSummary("""{"effect":"invoke","module":"m","method":"f"}""", lbl)
  doAssert none.args.len == 0 and none.text == "an action: m.f()", none.text
  let bad = effectSummary("""{"effect":"invoke","module":"m","method":"f","args":"not json"}""", lbl)
  doAssert "not json" in bad.text, "arguments that do not parse are shown as they are: " & bad.text
  echo "2. JSON-text args, no args and unparseable args are each shown as they are OK"

echo "invoke_summary_test: all OK"
