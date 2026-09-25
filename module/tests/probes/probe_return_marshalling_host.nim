## derived-exo-526 c1: a REAL HOST CLIENT invoking methods on the built
## muster_module observes each return as its declared typed string value —
## health() is exactly "ok"; propose(valid/edge effect JSON) is a non-empty
## intent id; status(that id) is a known lifecycle-state token — never a bool and
## never empty/default.
##
## The reported defect (`logoscore --call muster_module.health()` returning
## `Result: false`) lives on the Nim -> C++ -> host-client return-marshalling
## path, not inside the Nim core (which returns "ok"). So this probe does NOT
## stop at logos_module_dispatch: it links the module's Nim staticlib into a C++
## host harness (tests/probes/host_return_harness.cpp) that reproduces the shipped
## cdylib marshalling — dispatch -> nlohmann::json::parse ->
## logos::nlohmannToQVariant -> the CLI's `QVariant::toString()` — and reads the
## value a CLIENT would observe. A JSON string surfaces as a typed QString; a
## JSON bool surfaces as QVariant(bool) and prints "false" (the exact regression);
## a null/dropped return surfaces as empty. The harness judges nothing; this probe
## and the spec's `always(client_return_typed)` own the verdict.
##
## Emits one {"client_return_typed": ...} object per observed call. `always`
## requires every call — health, propose across a valid/edge family, and status
## of each resulting id — to be observed as its typed string.

import std/[json, os, osproc, strutils]

const
  moduleRoot = currentSourcePath().parentDir().parentDir().parentDir()  # module/
  nimLibMain = moduleRoot / "nim-lib" / "muster_module.nim"
  harnessCpp = moduleRoot / "tests" / "probes" / "host_return_harness.cpp"

proc fail(msg: string) =
  ## A build/link/run failure is INCONCLUSIVE, never a silent pass: emit a loud
  ## false observation (so `always` fails) and abort with a diagnosis.
  echo "{\"client_return_typed\": false, \"inconclusive\": \"", msg, "\"}"
  quit("probe_return_marshalling_host: " & msg, 1)

proc run(cmd: string, args: seq[string]): tuple[output: string, code: int] =
  let (o, c) = execCmdEx(quoteShellCommand(@[cmd] & args))
  (o, c)

# ── linker flags for a C library the module core links (secp256k1; libsodium for the
#    F-14 encryption identity and the keystore). The module build supplies them via
#    nix.packages, mirroring tests/README's --passL guidance. Prefer an explicit env
#    override, then pkg-config, then the nix store, then a bare -l<lib>. Returns raw
#    linker tokens; callers prefix them for nim (--passL:) or pass them to g++ as-is. ──
proc libTokens(envVar, pcName, lib: string): seq[string] =
  let env = getEnv(envVar)
  if env.len > 0:
    for tok in env.split():
      if tok.len > 0: result.add tok
    return result
  let (pc, code) = run("pkg-config", @["--libs", pcName])
  if code == 0 and pc.strip().len > 0:
    for tok in pc.split():
      if tok.len > 0: result.add tok
    return result
  # Hermetic fallback (exo-a5d): the exophial oracle regate scrubs PATH/env, so
  # `nix`/`pkg-config` and an ambient LIBRARY_PATH are all unavailable to point at
  # the nix-store library. Locate it by a filesystem-only glob over the
  # world-readable store — no binary needed — preferring a non-`-dev` output that
  # actually holds the library.
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir: continue
    let name = path.extractFilename
    if (lib & "-") notin name or name.endsWith("-dev"): continue
    let libDir = path / "lib"
    if fileExists(libDir / ("lib" & lib & ".so")) or fileExists(libDir / ("lib" & lib & ".a")):
      # -rpath embeds the store libdir so the harness also finds lib<lib>.so.N
      # at RUN time (LD_LIBRARY_PATH is scrubbed too), not just at link time.
      return @["-L" & libDir, "-Wl,-rpath," & libDir, "-l" & lib]
  @["-l" & lib]

proc secpTokens(): seq[string] = libTokens("MUSTER_SECP256K1_LIB", "libsecp256k1", "secp256k1")
proc sodiumTokens(): seq[string] = libTokens("MUSTER_SODIUM_LIB", "libsodium", "sodium")

# ── the module's Nim closure (logos_sdk, nim-secp256k1, stint, the web3 stack). The
#    staticlib compiles nim-lib/muster_module.nim, which imports all of it, but this
#    probe's own `nim r` flags do not reach the inner `nim c`. Read the packages
#    metadata.json pins (codegen.nim.packages) and put each one's import root on the
#    path, from the closure dir tests/run-suite.sh materializes ($MUSTER_NIMPKGS,
#    else ~/.cache/muster/nimpkgs). File reads only, so it survives a scrubbed env
#    as far as $HOME does. A missing closure adds nothing, and the build fails loudly. ──
proc closurePaths(): seq[string] =
  var root = getEnv("MUSTER_NIMPKGS")
  if root.len == 0:
    let home = getEnv("HOME")
    if home.len == 0: return
    root = home / ".cache" / "muster" / "nimpkgs"
  if not dirExists(root): return
  let meta = parseJson(readFile(moduleRoot / "metadata.json"))
  for p in meta["codegen"]["nim"]["packages"]:
    var dir = root / p["repo"].getStr()
    if p.hasKey("subdir"): dir = dir / p["subdir"].getStr()
    if dirExists(dir): result.add "--path:" & dir

let tmp = getTempDir() / "muster_exo526_host"
createDir(tmp)
let staticLib = tmp / "libmuster_module_probe.a"
let harnessBin = tmp / "host_return_harness"

# 1. Build the module as a Nim STATICLIB — exactly the shape the real cdylib
#    build produces (codegen.nim.staticlib), so the harness links the same
#    logos_module_* C ABI the shipped host loads.
block buildStatic:
  var args = @[
    "c", "-d:release", "--app:staticlib", "--noMain:on",
    "--nimcache:" & (tmp / "nc"),
    "-o:" & staticLib,
  ]
  for tok in secpTokens(): args.add "--passL:" & tok
  args.add closurePaths()
  args.add nimLibMain
  let (o, c) = run("nim", args)
  if c != 0 or not fileExists(staticLib):
    fail("nim staticlib build failed:\n" & o)

# 2. Compile + link the C++ host harness against the staticlib (+ secp256k1).
#    This is the real Nim -> C++ boundary; no module internals are mocked.
block buildHarness:
  var args = @[harnessCpp, staticLib, "-O2", "-o", harnessBin]
  args.add secpTokens()
  args.add sodiumTokens()
  let (o, c) = run("g++", args)
  if c != 0 or not fileExists(harnessBin):
    fail("g++ harness link failed:\n" & o)

# 3. Run the harness — a real host client reading client-observed returns.
let (harnessOut, code) = run(harnessBin, @[])
if code != 0:
  fail("host harness exited non-zero (" & $code & "):\n" & harnessOut)

var observed = 0
var allTyped = true
for line in harnessOut.splitLines():
  let s = line.strip()
  if not s.startsWith("{"): continue
  if "\"lp_stub_calls\"" in s: echo s        # diagnostic, not an observation
  if "\"client_return_typed\"" notin s: continue
  echo s                                   # surface every observation to the runner
  inc observed
  if "\"client_return_typed\": true" notin s:
    allTyped = false

if observed == 0:
  fail("harness produced no client observations")

doAssert allTyped,
  "a host client observed a non-typed (bool/empty/default) return — the " &
  "Nim->C++->host marshalling dropped a declared QString value"
