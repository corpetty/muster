## T1 of exo-607: the seaqt toolchain end to end. One nimside `qobject:`, one QML file,
## bound both ways. `seaqt-hello` opens a window; `seaqt-hello --self-test` asserts the
## three directions the real backend depends on and exits non-zero on any failure:
##   QML → Nim  a slot call with an argument (`poke`)
##   QML → Nim  a property write through the generated setter (`answer`)
##   Nim → QML  a property change reaching a QML binding (`greeting` → root.seen)

import std/os
import nimside, seaqt/[qguiapplication, qqmlapplicationengine, qqmlcontext, qurl, qvariant]
import seaqt/QtCore/qtcore_pkg # QtCoreBuildVersion: the Qt this binary was compiled against

qobject:
  type Greeter = ref object of VirtualQObject
    greeting {.qproperty.}: string
    answer {.qproperty.}: string
    heard: string

  proc poke(g: Greeter, what: string) {.slot, raises: [].} =
    g.heard = what

  proc create(T: type Greeter, greeting: string): Greeter =
    let res = T(greeting: greeting)
    QObject.create(res)
    res

proc qmlPath(): string =
  getAppDir() / ".." / "share" / "seaqt-hello" / "hello.qml"

proc main(): int =
  let
    selfTest = "--self-test" in commandLineParams()
    _ = QGuiApplication.create()
    backend = Greeter.create("hello from nim")
    engine = QQmlApplicationEngine.create()

  engine.rootContext().setContextProperty("backend", backend[])
  engine.load(QUrl.fromLocalFile(qmlPath()))
  let roots = engine.rootObjects()
  if roots.len == 0:
    echo "FAIL: the QML did not load (", qmlPath(), ")"
    return 1
  if not selfTest:
    return QGuiApplication.exec().int

  var failed = 0
  template check(ok: bool, what: string) =
    echo (if ok: "PASS: " else: "FAIL: "), what
    if not ok: inc failed

  let root = roots[0]
  check backend.heard == "hello from nim",
    "QML called the poke slot with the bound greeting (got '" & backend.heard & "')"
  check backend.answer == "from-qml",
    "QML wrote the answer property through its setter (got '" & backend.answer & "')"
  backend.setGreeting("changed in nim")
  let seen = root.property("seen").toString()
  check seen == "changed in nim",
    "a Nim property change reached the QML binding (root.seen = '" & seen & "')"
  echo if failed == 0: "SUCCESS: seaqt + nimside bind both ways on Qt " & QtCoreBuildVersion
       else: "FAILED: " & $failed & " check(s)"
  failed

quit main()
