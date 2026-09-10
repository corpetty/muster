# Package
version       = "0.1.0"
author        = "Muster / Logos"
description   = "Logos Nim SDK — runtime + LIDL codegen for Nim Logos modules (mirror of logos-rust-sdk)"
license       = "MIT OR Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

# The runtime (ffi/plugin/api) binds lp_* symbols resolved only at plugin link
# time, so it does not run under `nim r`; the codec (bytes) and the generator's
# pure JsonNode→Nim procs are unit-testable headlessly.
task test, "run the headless unit tests":
  exec "nim r --hints:off tests/tbytes.nim"
  exec "nim r --hints:off tests/tgen.nim"
