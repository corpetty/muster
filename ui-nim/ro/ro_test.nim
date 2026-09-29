## exo-607 T3: QtRemoteObjects from Nim, through the generated seaqt bindings.
##
## One process, one Qt event loop (QCoreApplication), no C++ written by hand:
##   source   a nimside `qobject:` (greeting {.qproperty.}: string, slot poke(what))
##   host     QRemoteObjectHost on local:<unique>, enableRemoting(source, "Greeter")
##   replica  QRemoteObjectNode.connectToNode(local:<unique>).acquireDynamic("Greeter")
## and asserts the three directions a Nim UI talking to a remoted backend depends on:
##   source → replica  the initial property value
##   replica → source  a slot call with a string argument
##   source → replica  a property change after init
##   replica → source  a property write on the replica
## It also dumps the replica's dynamic metaobject (and the source's, for comparison), so
## the record shows what QtRO derived from a nimside source. Exits non-zero on failure.

import std/[monotimes, os, times]
import nimside
import seaqt/[qcoreapplication, qeventloop, qurl, qvariant, qobject, qmetaobject, qmetamethod, qmetaproperty, qgenericargument]
import seaqt/[qremoteobjectnode, qremoteobjectreplica, qremoteobjectdynamicreplica]
# Every other generated RemoteObjects module, unused: importing one runs its {.compile.}
# pragma, so this build also proves all ten generated C++ wrappers compile and link.
import seaqt/[qabstractitemmodelreplica, qconnectionabstractserver, qremoteobjectpendingcall,
  qremoteobjectregistry, qremoteobjectsettingsstore, qremoteobjectsourcelocationinfo,
  qtroclientfactory, qtroserverfactory, sourceapimap, modelinfo]
import seaqt/QtCore/qtcore_pkg
import seaqt/QtRemoteObjects/qtremoteobjects_pkg

qobject:
  type Greeter = ref object of VirtualQObject
    greeting {.qproperty.}: string
    heard: string
    pokes: int

  proc poke(g: Greeter, what: string) {.slot, raises: [].} =
    g.heard = what
    inc g.pokes

  proc create(T: type Greeter, greeting: string): Greeter =
    let res = T(greeting: greeting)
    QObject.create(res)
    res

proc pumpUntil(cond: proc (): bool, timeoutMs = 5000): bool =
  ## Spin the one event loop until `cond` holds or the deadline passes.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    QCoreApplication.processEvents(cint QEventLoopProcessEventsFlagEnum.AllEvents, cint 20)
    if cond():
      return true
    sleep 1
  cond()

proc methodTypeName(t: cint): string =
  case t
  of 0: "method"
  of 1: "signal"
  of 2: "slot"
  of 3: "constructor"
  else: "?" & $t

proc bytesToString(b: seq[byte]): string =
  result = newString(b.len)
  for i, c in b: result[i] = char(c)

proc dumpMetaObject(label: string, mo: QMetaObject) =
  echo "---- ", label, ": class ", $mo.className(),
    " (properties ", mo.propertyOffset(), "..", mo.propertyCount() - 1,
    ", methods ", mo.methodOffset(), "..", mo.methodCount() - 1, " are its own)"
  for i in mo.propertyOffset() ..< mo.propertyCount():
    let p = mo.property(cint i)
    echo "  property[", i, "] ", $p.typeName(), " ", $p.name(),
      (if p.isWritable(): " WRITE" else: ""),
      (if p.hasNotifySignal(): " NOTIFY#" & $p.notifySignalIndex() else: "")
  for i in mo.methodOffset() ..< mo.methodCount():
    let m = mo.methodX(cint i)
    let ret = $m.typeName()
    echo "  method[", i, "] ", methodTypeName(m.methodType()), " ",
      (if ret.len > 0 and ret != "void": ret & " " else: ""),
      bytesToString(m.methodSignature())

proc main(): int =
  var failed = 0
  template check(cond: bool, what: string) =
    let ok = cond # evaluate once: some checks are calls with side effects (enableRemoting)
    echo (if ok: "PASS: " else: "FAIL: "), what
    if not ok: inc failed

  let
    _ = QCoreApplication.create()
    url = QUrl.create("local:seaqt-ro-test-" & $getCurrentProcessId())
    source = Greeter.create("hello from the source")

  echo "Qt: built against ", QtCoreBuildVersion, ", RemoteObjects bindings generated from ",
    QtRemoteObjectsGenVersion, " (built against ", QtRemoteObjectsBuildVersion, ")"

  # --- source side
  let host = QRemoteObjectHost.create(url)
  check host.enableRemoting(source[], "Greeter"),
    "QRemoteObjectHost(" & url.toString() & ").enableRemoting(<nimside Greeter>, \"Greeter\")"

  # --- replica side (same process, same event loop)
  let node = QRemoteObjectNode.create()
  check node.connectToNode(url), "QRemoteObjectNode.connectToNode(" & url.toString() & ")"
  let replica = node.acquireDynamic("Greeter")
  check replica.h != nil, "acquireDynamic(\"Greeter\") returned a replica"
  if replica.h == nil:
    return 1

  let inited = pumpUntil(proc (): bool = replica.isInitialized())
  check inited, "the dynamic replica initialized (state " & $replica.state() &
    ", valid " & $replica.isReplicaValid() & ")"
  if not inited:
    return 1

  # 1. source → replica: the initial property value
  let initial = replica.property("greeting").toString()
  check initial == "hello from the source",
    "replica.greeting reads the source's value (got '" & initial & "')"

  # 2. replica → source: a slot call with a string argument, via QMetaObject.invokeMethod
  #    on the replica. The QString lives inside a QVariant; constData() is its address.
  let arg = QVariant.create("poked through the replica")
  let invoked = QMetaObject.invokeMethod(replica, "poke",
    QGenericArgument.create("QString", arg.constData()))
  check invoked, "QMetaObject.invokeMethod(replica, \"poke\", QString) was accepted"
  let reached = pumpUntil(proc (): bool = source.pokes > 0)
  check reached and source.heard == "poked through the replica",
    "the call reached the source's Nim slot (pokes " & $source.pokes &
    ", heard '" & source.heard & "')"

  # 3. source → replica: a change after init
  source.setGreeting("changed at the source")
  let propagated = pumpUntil(proc (): bool =
    replica.property("greeting").toString() == "changed at the source")
  check propagated, "source.setGreeting propagated to the replica (replica.greeting = '" &
    replica.property("greeting").toString() & "')"

  # 4. replica → source: a property write on the replica (what a QML binding would do)
  discard replica.setProperty("greeting", QVariant.create("written at the replica"))
  let written = pumpUntil(proc (): bool = source.greeting == "written at the replica")
  check written, "a property write on the replica reached the source (source.greeting = '" &
    source.greeting & "')"

  # For the record: what QtRO derived from the nimside source.
  dumpMetaObject("source (nimside Greeter)", source[].metaObject())
  dumpMetaObject("replica (QRemoteObjectDynamicReplica of \"Greeter\")", replica.metaObject())

  echo if failed == 0: "SUCCESS: QtRemoteObjects from Nim — host, dynamic replica, property + slot, both ways"
       else: "FAILED: " & $failed & " check(s)"
  failed

quit main()
