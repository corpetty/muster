## `repContract` turns a `.rep` view contract into a nimside `qobject:` declaration
## at compile time: a repc for nimside. The `.rep` stays the one source of truth: the
## C++ build's repc and this macro read the same file, so the two backends cannot
## drift, and the order QtRO binds by index is the file's order in both.
##
##   repContract(MusterUi, "…/muster_ui.rep")
##
## declares `MusterUi`, a nimside QObject with:
##   * every PROP as a notifying property that QML can read but not write, which is
##     repc's READONLY. Nim sets it with a generated `setX(o, v)` that emits
##     `xChanged` only when the value changes;
##   * every SLOT as a nimside slot that forwards to `<slot>Impl(o, args…)`. Those are
##     forward declarations the calling module must implement: leave one out and the
##     compile fails, like a pure virtual in C++. An exception from an Impl is caught
##     in the slot and reported, so it never unwinds into Qt's C++ frames;
##   * `create(T)`, which builds the object with every PROP at its `.rep` default;
##   * `setContractProp(o, name, v)`, which sets a PROP by its `.rep` name;
##   * `<T>ContractSource`, the generated declaration as text.
##
## Only the forms `ui/src/muster_ui.rep` uses are mapped: QString PROPs and void SLOTs
## of QString parameters. Anything else is a compile error naming it.

import std/[macros, strutils]
import ./repparse
export repparse

proc nimType(qt: string, what: string): string =
  case qt
  of "QString": "string"
  else:
    error("repContract maps only QString, but " & what & " is " & qt)

const nimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard", "distinct", "div", "do",
  "elif", "else", "end", "enum", "except", "export", "finally", "for", "from", "func", "if",
  "import", "in", "include", "interface", "is", "isnot", "iterator", "let", "macro", "method",
  "mixin", "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise",
  "ref", "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var",
  "when", "while", "xor", "yield"]

proc q(name: string): string =
  ## A .rep name as a Nim identifier. Plain, never backtick-quoted: nimside reads slot
  ## and property names with strVal, which an accent-quoted name would break.
  if name.normalize in nimKeywords:
    error("the .rep name '" & name & "' is a Nim keyword")
  name

proc reportSlotError*(slot, msg: string) {.raises: [].} =
  ## Where a slot's Impl exception ends up: stderr, then the slot returns normally.
  try:
    stderr.writeLine "[muster_ui] slot " & slot & " raised: " & msg
  except IOError:
    discard

proc setterName(prop: string): string = "set" & prop[0].toUpperAscii & prop[1 .. ^1]

proc contractSource(T: string, rep: RepClass): string =
  # A generated Nim setter must not shadow a SLOT of the same name.
  for p in rep.props:
    for sl in rep.slots:
      if cmpIgnoreStyle(setterName(p.name), sl.name) == 0:
        error("PROP " & p.name & "'s setter collides with SLOT " & sl.name)
  var s = "qobject:\n  type " & T & "* = ref object of VirtualQObject\n"
  for p in rep.props:
    let t = nimType(p.typ, "PROP " & p.name)
    s.add "    " & q(p.name) & " {.qproperty(write = false).}: " & t & "\n"
  # Forward declarations: the calling module implements each one.
  for sl in rep.slots:
    var params = "o: " & T
    for p in sl.params:
      params.add ", " & q(p.name) & ": " & nimType(p.typ, "SLOT " & sl.name & " parameter " & p.name)
    s.add "  proc " & q(sl.name & "Impl") & "(" & params & ")\n"
  for sl in rep.slots:
    var params = "o: " & T
    var args = "o"
    for p in sl.params:
      params.add ", " & q(p.name) & ": " & nimType(p.typ, "")
      args.add ", " & q(p.name)
    s.add "  proc " & q(sl.name) & "(" & params & ") {.slot, raises: [].} =\n"
    s.add "    try: " & q(sl.name & "Impl") & "(" & args & ")\n"
    s.add "    except Exception as e: reportSlotError(" & escape(sl.name) & ", e.msg)\n"
  # Nim-side setters: QML cannot write a READONLY PROP, the backend can.
  for p in rep.props:
    s.add "proc " & q(setterName(p.name)) & "*(o: " & T & ", v: " & nimType(p.typ, "") & ") =\n"
    s.add "  if o." & q(p.name) & " != v:\n"
    s.add "    o." & q(p.name) & " = v\n"
    s.add "    o." & q(p.name & "Changed") & "()\n"
  # Set a PROP by its .rep name: the contract check, and routing a module result by name.
  s.add "proc setContractProp*(o: " & T & ", name, v: string): bool =\n  case name\n"
  for p in rep.props:
    s.add "  of " & escape(p.name) & ": o." & q(setterName(p.name)) & "(v)\n"
  s.add "  else: return false\n  true\n"
  s.add "proc create*(_: type " & T & "): " & T & " =\n"
  s.add "  let res = " & T & "("
  var first = true
  for p in rep.props:
    if not first: s.add ", "
    first = false
    s.add q(p.name) & ": " & escape(p.default)
  s.add ")\n  QObject.create(res)\n  res\n"
  s

macro repContract*(T: untyped, repFile: static string): untyped =
  ## Declare the nimside QObject `T` from the `.rep` at `repFile` (see the module doc).
  let rep =
    try: parseRep(staticRead(repFile))
    except RepError as e:
      error(e.msg, T)
  let src = contractSource($T, rep)
  result = parseStmt(src)
  # The expanded declaration, kept in the binary so it can be read back (--dump):
  # what the DSL is asked to express, for whoever designs it.
  result.add newConstStmt(postfix(ident($T & "ContractSource"), "*"), newLit(src))

macro repStubs*(T: untyped, repFile: static string, log: untyped): untyped =
  ## Implement every `<slot>Impl` of `repContract(T, repFile)` by appending the call,
  ## "name(arg,…)", to the seq[string] `log`. For the contract check (and a stand-in
  ## until the real backend lands), never for the shipped UI.
  let rep = parseRep(staticRead(repFile))
  var s = ""
  for sl in rep.slots:
    var params = "o: " & $T
    var call = escape(sl.name & "(")
    for i, p in sl.params:
      params.add ", " & q(p.name) & ": string"
      call.add " & " & (if i > 0: "\",\" & " else: "") & q(p.name)
    call.add " & \")\""
    s.add "proc " & q(sl.name & "Impl") & "(" & params & ") =\n"
    s.add "  " & $log & ".add " & call & "\n"
  parseStmt(s)
