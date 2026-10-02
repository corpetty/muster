# The probes' Nim closure for a run that does NOT go through run-suite.sh (exo-a7b).
#
# The spec grader (scripts/grade-specs.sh → exophial's spec_oracle) runs each probe as a
# bare `nim r -d:release tests/probes/<probe>.nim` in an ALLOWLISTED environment: HOME is
# a scratch directory and no MUSTER_* variable reaches it, so neither ~/.cache nor an env
# var can say where the pinned packages and libsodium live. They are found instead through
# links inside the tree — module/.probe-env/{nimpkgs,sodium} (gitignored) — which
# grade-specs.sh refreshes from tools/nim-closure.sh and nixpkgs' libsodium before
# grading. With no .probe-env this adds nothing, and run-suite.sh's own flags stand
# (extra --path entries are harmless when both are present).
import std/os

let env = thisDir() / ".." / ".." / ".probe-env"
let pk = env / "nimpkgs"
if dirExists(pk):
  for p in ["nim-secp256k1", "nim-stew", "nim-results", "nimcrypto", "nim-stint",
            "nim-intops/src", "nim-eth", "nim-web3", "nim-chronos", "nim-chronicles",
            "nim-bearssl", "nim-faststreams", "nim-json-rpc", "nim-serialization",
            "nim-json-serialization", "nim-http-utils", "logos-nim-sdk/src"]:
    switch("path", pk / p)
let sodium = env / "sodium"
if fileExists(sodium / "libsodium.so"):
  switch("passL", sodium / "libsodium.so")
  switch("passL", "-Wl,-rpath," & sodium)
# ...and the gcc from the same nixpkgs (exo-56a): a probe the host's gcc links loads the
# host's glibc, which may be older than the one that libsodium needs. Only under the grader
# (no MUSTER_NIMPKGS, as closurePaths reads it); run-suite.sh puts its own on PATH.
let cc = env / "cc"
if getEnv("MUSTER_NIMPKGS").len == 0 and fileExists(cc / "gcc"):
  switch("gcc.exe", cc / "gcc")
  switch("gcc.linkerexe", cc / "gcc")
  switch("gcc.cpp.exe", cc / "g++")
  switch("gcc.cpp.linkerexe", cc / "g++")
