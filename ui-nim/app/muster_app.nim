## T4a of exo-607, probe B: muster's UI as a standalone seaqt app. The real QML
## (ui/src/qml/Main.qml) runs in a Nim host, with no Basecamp, no ui-host and no QtRO.
## The backend is the T2 contract object, exposed to QML the way the Logos host
## exposes its bridge: a `logos` context property whose `module("muster_ui")`
## returns the backend.
##
## Step 1: the view loads and binds against the contract, with stub Impls that
## record each call.
## Step 2: the host starts logos-core itself (liblogos's C API, as
## logos-standalone-app does), registers the view's token with capability_module,
## and calls muster_module over lp_*, the ABI logos-nim-sdk binds (its ffi, token calls
## included, since logos-nim-sdk#6). checkHealth is
## implemented for real. A result arrives on the Qt main thread, where the client
## lives, so the callback sets the PROP directly.
##
##   muster-app [--modules <dir> --user-dir <dir>]   a window on a display; with
##                                                    --modules, backed by logos-core
##   muster-app --self-test                           offscreen: the view loads, stubs only
##   muster-app --self-test-core --modules <dir> --user-dir <dir>
##                                                    offscreen: + muster_module.health()

import std/[os, strutils, json, sysrand, times]
import nimside, seaqt/[qguiapplication, qcoreapplication, qquickview, qqmlengine,
  qqmlcontext, qqmlerror, qurl, qvariant, qwindow]
import logos_sdk/ffi
import ../contract/repcontract, ./logos_core

const
  musterRep {.strdefine.} = ""        ## ui/src/muster_ui.rep, the view contract
  musterQml {.strdefine.} = ""        ## ui/src/qml, the view itself
  logosQmlImports {.strdefine.} = ""  ## where Logos/Theme and Logos/Controls live
when musterRep.len == 0 or musterQml.len == 0:
  {.error: "build with -d:musterRep=<muster_ui.rep> -d:musterQml=<ui/src/qml>".}

var calls: seq[string]
repContract(MusterUi, musterRep)
repStubs(MusterUi, musterRep, calls, "checkHealth")

# ── muster_module over lp_* ─────────────────────────────────────────────────────
var musterClient: ptr LpClient   ## muster_module, called as muster_ui; nil without a core

proc onHealth(ok: cint, json: cstring, ud: pointer) {.cdecl, gcsafe.} =
  # Runs on the Qt main thread (the client's owner), so the PROP can be set here.
  {.cast(gcsafe).}:
    let backend = cast[MusterUi](ud)
    let raw = $json
    let value =
      try: (if ok != 0: parseJson(raw).getStr(raw) else: "error: " & raw)
      except CatchableError: raw
    backend.setHealth(value)

proc checkHealthImpl(o: MusterUi) =
  calls.add "checkHealth()"
  if musterClient != nil:
    discard lp_invoke_async(musterClient, "health", "[]", 20_000, onHealth, cast[pointer](o))

proc startCore(modulesDir, userDir: string): string =
  ## Start logos-core in this process and connect as muster_ui. "" on success, else why not.
  logos_core_add_modules_dir(modulesDir.cstring)
  logos_core_set_persistence_base_path(cstring(userDir / "module_data"))
  logos_core_start()
  if logos_core_load_module("capability_module", false) == 0:
    return "capability_module did not load"
  if logos_core_load_module("muster_module", true) == 0:
    return "muster_module did not load"
  let capToken = hostToken("capability_module")
  if capToken.len == 0:
    return "the core holds no capability_module token"
  # Register this view with capability_module, as the Logos host does for a view
  # module (logos-standalone-app's informModuleToken): the core's capability
  # token vouches for a fresh token that this process then presents as muster_ui.
  discard lp_token_save("capability_module", capToken.cstring)
  let cap = lp_client_create("capability_module", "core", nil, nil)
  if cap == nil:
    return "no capability_module client"
  var uiToken = ""
  for b in urandom(16): uiToken.add b.toHex(2).toLowerAscii
  if lp_inform_module_token(cap, capToken.cstring, "muster_ui", uiToken.cstring) != LP_OK:
    return "capability_module refused the view's token"
  discard lp_token_save("core", uiToken.cstring)
  discard lp_token_save("capability_module", uiToken.cstring)
  musterClient = lp_client_create("muster_module", "muster_ui", nil, nil)
  if musterClient == nil:
    return "no muster_module client"
  ""

# ── the Logos host's QML bridge, as much of it as muster's QML uses ─────────────
qobject:
  type LogosShim = ref object of VirtualQObject
    backend: MusterUi

  proc viewModuleReadyChanged(o: LogosShim, moduleName: string, isReady: bool) {.signal.}

  proc module(o: LogosShim, name: string): QObject {.slot, raises: [].} =
    if name == "muster_ui":
      result = QObject(h: o.backend[].h, owned: false)

  proc isViewModuleReady(o: LogosShim, name: string): bool {.slot, raises: [].} =
    name == "muster_ui"

  proc create(T: type LogosShim, backend: MusterUi): LogosShim =
    let res = T(backend: backend)
    QObject.create(res)
    res

# ── main ────────────────────────────────────────────────────────────────────────
proc arg(name: string): string =
  let ps = commandLineParams()
  let i = ps.find(name)
  if i >= 0 and i + 1 < ps.len: ps[i + 1] else: ""

proc pumpUntil(cond: proc(): bool, seconds: float) =
  let deadline = epochTime() + seconds
  while not cond() and epochTime() < deadline:
    QCoreApplication.processEvents()
    sleep(10)

proc main(): int =
  let
    ps = commandLineParams()
    selfTest = "--self-test" in ps
    selfTestCore = "--self-test-core" in ps
    modulesDir = arg("--modules")
    userDir = arg("--user-dir")
    _ = QGuiApplication.create()
    backend = MusterUi.create()
    logos = LogosShim.create(backend)

  var failed = 0
  template check(ok: bool, what: string) =
    echo (if ok: "PASS: " else: "FAIL: "), what
    if not ok: inc failed

  if modulesDir.len > 0:
    if userDir.len == 0:
      quit "--modules needs --user-dir", 2
    createDir(userDir)
    let err = startCore(modulesDir, userDir)
    check err.len == 0, "logos-core started in this process; muster_module loaded; " &
      "the view's token registered with capability_module" & (if err.len > 0: " (" & err & ")" else: "")
    if err.len > 0:
      logos_core_cleanup()
      return 1

  let
    view = QQuickView.create()
    imports = getEnv("MUSTER_QML_IMPORT", logosQmlImports)
  for dir in imports.split(':'):
    if dir.len > 0: view.engine().addImportPath(dir)
  view.rootContext().setContextProperty("logos", logos[])
  view.setResizeMode(1) # SizeRootObjectToView
  view.setSource(QUrl.fromLocalFile(musterQml / "Main.qml"))
  let errs = view.errors()
  for e in errs: echo "QML: ", e.toString()
  check view.status() == 1 and errs.len == 0,
    "Main.qml loaded in a seaqt host: status Ready, no QML errors"
  if failed > 0:
    if modulesDir.len > 0: logos_core_cleanup()
    return 1

  # What the C++ backend's onContextReady does first: ask the module for its health.
  checkHealthImpl(backend)

  if not (selfTest or selfTestCore):
    view.resize(1280, 860)
    view.show()
    let rc = QGuiApplication.exec().int
    if modulesDir.len > 0: logos_core_cleanup()
    return rc

  let root = view.rootObject()
  check root.property("ready").toBool(),
    "the view is ready: logos.module(\"muster_ui\") returned the Nim backend"
  check calls.len > 0, "QML called the backend while loading (" & $calls.len & " call(s))"
  for c in calls: echo "  ", c

  if selfTestCore:
    pumpUntil(proc(): bool = backend.health != "unknown", 60)
    check backend.health == "ok",
      "muster_module.health() over lp_*, from this Nim host, set the health PROP to '" &
      backend.health & "'"
    logos_core_cleanup()

  echo if failed == 0: "SUCCESS: muster's real QML runs in a Nim host" &
         (if selfTestCore: ", backed by muster_module through logos-core" else: " against the contract")
       else: "FAILED: " & $failed & " check(s)"
  failed

quit main()
