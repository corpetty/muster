#!/usr/bin/env python3
"""Generate the autovoice harness: ui-nim/app/backend.nim, included whole, against stubs.

  gen.py <repo> <out dir> <backend.nim>

ui-nim's flake builds on Linux only, so this check stands in for the Nim app where it
cannot be built (a Mac). The stubs come from the sources the real build generates its own
from, so they cannot drift from it:
  * MusterUi, the contract: every PROP of ui/src/muster_ui.rep a string field and its
    setX, every SLOT a forward-declared <slot>Impl (backend.nim defines them all);
  * MusterClient, the muster_module client: every method of module/src/api/muster.lidl an
    <m>Async(c, args..., done): bool whose answer fake_module.nim gives. The answer is
    queued and delivered on a later turn of the loop, as the SDK's lands later on the Qt
    thread;
  * seaqt's QTimer, whose one timeout closure (sched.nim's ticker) the loop calls every
    20 ms of real time, and QStandardPaths.
The loop runs HARNESS_SECS seconds of real time, then fake_module.nim's report().
"""
import pathlib
import re
import sys

repo, out, backend = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
here = pathlib.Path(__file__).resolve().parent
rep = re.sub(r"//[^\n]*", "", (repo / "ui/src/muster_ui.rep").read_text())
props = re.findall(r"PROP\(\s*QString\s+(\w+)\s*=", rep)
slots = re.findall(r"SLOT\(\s*void\s+(\w+)\s*\(([^)]*)\)", rep)
lidl = (repo / "module/src/api/muster.lidl").read_text()
methods = re.findall(r"^\s*method\s+(\w+)\(([^)]*)\)\s*->\s*tstr", lidl, re.M)
if not props or not slots or not methods:
    sys.exit("gen.py: read %d props, %d slots, %d methods" % (len(props), len(slots), len(methods)))

L = ["import std/[json, os, times, strutils]", "type MusterClient = ref object", "",
     'include "%s"' % (here / "fake_module.nim"), ""]
for name, params in methods:
    ps = [p.split(":")[0].strip() for p in params.split(",") if p.strip()]
    sig = "".join(", %s: string" % p for p in ps)
    args = "@[" + ", ".join(ps) + "]" if ps else "newSeq[string]()"
    L.append("proc %sAsync(c: MusterClient%s, done: proc (r: string) {.closure.}): bool =" % (name, sig))
    L.append("  let a = %s" % args)
    L.append('  queued.add (proc () = done(fake("%s", a)))' % name)
    L.append("  true")
L += ["", "type MusterUi = ref object"]
L += ["  %s: string" % p for p in props]
L += ["proc set%s%s(o: MusterUi, v: string) = o.%s = v" % (p[0].upper(), p[1:], p) for p in props]
for name, params in slots:
    ps = [re.findall(r"(\w+)\s*$", p.strip())[0] for p in params.split(",") if p.strip()]
    L.append("proc %sImpl(o: MusterUi%s)" % (name, "".join(", %s: string" % p for p in ps)))
L += ["", "var coreUp = false", "let mm = MusterClient()",
      'include "%s"' % backend, "",
      "import seaqt/qtimer",
      "coreUp = true",
      "let ui = MusterUi()",
      "ui.contextReady()",
      "let t0 = epochTime()",
      'let runFor = parseFloat(getEnv("HARNESS_SECS", "10"))',
      "while epochTime() - t0 < runFor:",
      "  let now = queued",
      "  queued = @[]",
      "  for q in now: q()",
      "  if gTick != nil: gTick()",
      "  sleep(20)",
      "report()", ""]
(out / "harness.nim").write_text("\n".join(L))
(out / "seaqt").mkdir(exist_ok=True)
(out / "seaqt/qstandardpaths.nim").write_text(
    "type QStandardPaths* = object\n"
    "proc writableLocation*(T: typedesc[QStandardPaths], loc: cint): string = \"\"\n")
(out / "seaqt/qtimer.nim").write_text(
    "type QTimer* = object\n"
    "var gTick*: proc () {.closure, raises: [].}\n"
    "proc create*(T: typedesc[QTimer]): QTimer = QTimer()\n"
    "proc setInterval*(t: QTimer, ms: int) = discard\n"
    "proc onTimeout*(t: QTimer, fn: proc () {.closure, raises: [].}) = gTick = fn\n"
    "proc start*(t: QTimer) = discard\n")
print("harness: %d props, %d slots, %d methods" % (len(props), len(slots), len(methods)))
