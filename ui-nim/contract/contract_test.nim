## T2 of exo-607: muster's view contract (`ui/src/muster_ui.rep`) as a nimside
## `qobject:`, declared by `repContract` from the same file repc reads, and checked:
##   1. QtRO's view of it: the API a dynamic QtRO source derives from this object's
##      metaobject (properties, their notify signals, then every slot/method, in
##      metaobject order) against the API repc generates for the typed source, index by
##      index. A typed replica binds by index, so an order mismatch is fatal. A
##      signature that differs where QtRO does not look is recorded as a finding.
##   2. QML → Nim: every SLOT, called from QML with distinct string arguments, reaches
##      its Impl with those arguments, in order.
##   3. Nim → QML: every PROP reads from QML at its .rep default, reads again after the
##      Nim setter changes it, and refuses a write from QML (READONLY).
##   4. The real QML: every `backend.<name>` in ui/src/qml names a PROP, a SLOT or a
##      notify signal of the contract.
##   contract-test --repc <rep_muster_ui_source.h> --qml <ui/src/qml>
##   contract-test --dump     # print the nimside declaration repContract generated
## Exits non-zero on any fatal mismatch; prints PASS/FAIL/FINDING lines.

import std/[os, strutils, sequtils, json, sets, algorithm]
import nimside, seaqt/[qguiapplication, qqmlapplicationengine, qqmlcontext, qvariant,
  qmetaobject, qmetaproperty, qmetamethod]
import ./repcontract

const musterRep {.strdefine.} = ""
when musterRep.len == 0:
  {.error: "build with -d:musterRep=<path to ui/src/muster_ui.rep>".}

var calls: seq[string]
repContract(MusterUi, musterRep)
repStubs(MusterUi, musterRep, calls)

const repSource = staticRead(musterRep)
let rep = parseRep(repSource)

var fatal = 0
proc check(ok: bool, what: string) =
  echo (if ok: "PASS: " else: "FAIL: "), what
  if not ok: inc fatal
proc finding(what: string) = echo "FINDING: ", what

proc str(b: seq[byte]): string = cast[string](b)

# ── 1. QtRO's API view vs repc's ────────────────────────────────────────────────
type Api = object
  props, propTypes, signals, methods: seq[string]

proc between(s, a, b: string, start = 0): string =
  let i = s.find(a, start)
  if i < 0: return ""
  let j = s.find(b, i + a.len)
  if j < 0: return ""
  s[i + a.len ..< j]

proc repcApi(header: string): Api =
  ## Read the index tables repc writes into <Class>SourceAPI's constructor.
  for line in header.splitLines:
    if "qtro_property_index<ObjectType>(&ObjectType::" in line:
      result.props.add line.between("&ObjectType::", ",")
      result.propTypes.add line.between("static_cast<", " (QObject::*)")
    elif "qtro_signal_index<ObjectType>(&ObjectType::" in line:
      result.signals.add line.between("&ObjectType::", ",") & "(" &
        line.between("(QObject::*)(", ")>") & ")"
    elif "qtro_method_index<ObjectType>(&ObjectType::" in line:
      result.methods.add line.between(",\"", "\"")

proc dynamicApi(o: QObject): Api =
  ## What QtRO's DynamicApiMap derives (qremoteobjectsource.cpp): properties from
  ## the offset on, each property's notify signal, then the remaining signals, then
  ## every Slot/Method, all in metaobject order.
  let mo = o.metaObject()
  var notify: HashSet[int]
  for i in mo.propertyOffset() ..< mo.propertyCount():
    let p = mo.property(i)
    result.props.add $p.name()
    result.propTypes.add $p.typeName()
    let n = p.notifySignalIndex()
    if n >= 0:
      notify.incl n
      result.signals.add mo.methodX(n).methodSignature().str
  for i in mo.methodOffset() ..< mo.methodCount():
    let m = mo.methodX(i)
    case m.methodType()
    of QMetaMethodMethodTypeEnum.Signal:
      if i notin notify: result.signals.add m.methodSignature().str
    of QMetaMethodMethodTypeEnum.Slot, QMetaMethodMethodTypeEnum.Method:
      result.methods.add m.methodSignature().str
    else: discard

proc compareApi(nim, repc: Api) =
  check nim.props == repc.props,
    "properties: the same " & $repc.props.len & " names in the same order"
  check nim.propTypes.allIt(it == "QString") and repc.propTypes.allIt(it == "QString"),
    "properties: every one is a QString on both sides"
  let sigNames = proc(s: seq[string]): seq[string] = s.mapIt(it.split('(')[0])
  check sigNames(nim.signals) == sigNames(repc.signals),
    "signals: the same " & $repc.signals.len & " notify signals in the same order"
  if nim.signals != repc.signals:
    var ex = 0
    for i in 0 ..< min(nim.signals.len, repc.signals.len):
      if nim.signals[i] != repc.signals[i]:
        if ex == 0:
          finding "notify signals differ in signature, e.g. nim " & nim.signals[i] &
            " vs repc " & repc.signals[i] & ". QtRO carries a notify as a property " &
            "change by index and never reads its arguments, so this does not break binding."
        inc ex
    finding $ex & " of " & $repc.signals.len & " notify signatures differ that way"
  let head = nim.methods[0 ..< min(nim.methods.len, repc.methods.len)]
  check head == repc.methods,
    "methods: the first " & $repc.methods.len & " are the SLOTs, same signatures, same order"
  if head != repc.methods:
    for i in 0 ..< min(head.len, repc.methods.len):
      if head[i] != repc.methods[i]:
        echo "  first mismatch at method ", i, ": nim ", head[i], " vs repc ", repc.methods[i]
        break
  if nim.methods.len > repc.methods.len:
    let extra = nim.methods[repc.methods.len .. ^1]
    finding $extra.len & " extra methods follow the SLOTs (nimside's property accessor " &
      "slots, e.g. " & extra[0 ..< min(3, extra.len)].join(", ") & "). They sit after " &
      "the SLOTs, so a typed replica, which knows only the SLOTs' indices, never reaches them."

# ── 2 + 3. QML round trip ───────────────────────────────────────────────────────
proc argsFor(sl: RepSlot): seq[string] =
  toSeq(0 ..< sl.params.len).mapIt(sl.name & "." & $it)

proc harnessQml(): string =
  var snap, callsJs: seq[string]
  for p in rep.props:
    snap.add "\"" & p.name & "\": backend." & p.name
  for sl in rep.slots:
    callsJs.add "backend." & sl.name & "(" & argsFor(sl).mapIt("\"" & it & "\"").join(", ") & ")"
  "import QtQml\nQtObject {\n" &
    "  property string snapshot: JSON.stringify({" & snap.join(", ") & "})\n" &
    "  property string defaults: \"\"\n" &
    "  property string writeResult: \"\"\n" &
    "  Component.onCompleted: {\n" &
    "    defaults = snapshot\n" &
    "    " & callsJs.join("\n    ") & "\n" &
    "    try { backend." & rep.props[0].name & " = \"written from qml\"; writeResult = \"accepted\" }\n" &
    "    catch (e) { writeResult = \"refused: \" + e }\n" &
    "  }\n}\n"

proc roundTrip() =
  let
    backend = MusterUi.create()
    engine = QQmlApplicationEngine.create()
    qml = harnessQml()
  engine.rootContext().setContextProperty("backend", backend[])
  engine.loadData(qml.toOpenArrayByte(0, qml.high))
  let roots = engine.rootObjects()
  check roots.len == 1, "the harness QML loaded"
  if roots.len != 1: return
  let root = roots[0]

  var want: seq[string]
  for sl in rep.slots:
    want.add sl.name & "(" & argsFor(sl).join(",") & ")"
  check calls == want, "QML → Nim: all " & $rep.slots.len &
    " SLOTs reached their Impl, with their arguments, in order"
  if calls != want:
    for i in 0 ..< max(calls.len, want.len):
      let got = if i < calls.len: calls[i] else: "<none>"
      let exp = if i < want.len: want[i] else: "<none>"
      if got != exp:
        echo "  first difference at call ", i, ": got ", got, ", want ", exp
        break

  let defaults = parseJson(root.property("defaults").toString())
  check rep.props.allIt(defaults{it.name}.getStr("\x00") == it.default),
    "Nim → QML: all " & $rep.props.len & " PROPs read from QML at their .rep defaults"

  for p in rep.props:
    discard backend.setContractProp(p.name, "set:" & p.name)
  let after = parseJson(root.property("snapshot").toString())
  check rep.props.allIt(after{it.name}.getStr("") == "set:" & it.name),
    "Nim → QML: after the Nim setters, all " & $rep.props.len &
    " PROPs read their new values from QML (each notify re-evaluated the binding)"

  let wr = root.property("writeResult").toString()
  check wr.startsWith("refused"), "READONLY: QML cannot write a PROP (" & wr & ")"
  check backend.health == "set:" & rep.props[0].name, "READONLY: the refused write changed nothing"

# ── 4. the real QML ─────────────────────────────────────────────────────────────
proc qmlReferences(dir: string): HashSet[string] =
  for f in walkDirRec(dir):
    if not f.endsWith(".qml"): continue
    let src = readFile(f)
    var i = 0
    while (i = src.find("backend.", i); i >= 0):
      i += "backend.".len
      var id = ""
      while i < src.len and src[i] in IdentChars:
        id.add src[i]
        inc i
      if id.len > 0: result.incl id

proc qmlDrift(dir: string) =
  var known: HashSet[string]
  for p in rep.props:
    known.incl p.name
    known.incl p.name & "Changed"
  for sl in rep.slots: known.incl sl.name
  let used = qmlReferences(dir)
  let unknown = toSeq(used - known).sorted
  check unknown.len == 0, "the real QML: every one of " & $used.len &
    " backend.<name> references is in the contract" &
    (if unknown.len > 0: " (not in it: " & unknown.join(", ") & ")" else: "")
  var unused: seq[string]
  for sl in rep.slots:
    if sl.name notin used: unused.add sl.name
  for p in rep.props:
    if p.name notin used and (p.name & "Changed") notin used: unused.add p.name
  if unused.len > 0:
    finding $unused.len & " contract entries are never named as backend.<x> in the QML " &
      "(the autopilot or a Connections block may still use them): " & unused.sorted.join(", ")

# ── main ────────────────────────────────────────────────────────────────────────
proc arg(name: string): string =
  let ps = commandLineParams()
  let i = ps.find(name)
  if i < 0 or i + 1 >= ps.len:
    quit "usage: contract-test --repc <rep_muster_ui_source.h> --qml <ui/src/qml>", 2
  ps[i + 1]

if "--dump" in commandLineParams():
  echo MusterUiContractSource
  quit 0

let
  _ = QGuiApplication.create()
  repcHeader = readFile(arg("--repc"))
  qmlDir = arg("--qml")

echo "contract: ", rep.name, " — ", rep.props.len, " PROPs, ", rep.slots.len, " SLOTs"
compareApi(dynamicApi(MusterUi.create()[]), repcApi(repcHeader))
roundTrip()
qmlDrift(qmlDir)
echo (if fatal == 0: "SUCCESS: the nimside declaration is muster's view contract, index for index"
      else: "FAILED: " & $fatal & " check(s)")
quit fatal
