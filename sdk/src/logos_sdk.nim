## Logos Nim SDK — the runtime behind typed, generated clients a Nim Logos module
## uses to call other modules, and the module-side context/emit/token seam its
## generated surface delegates to. The Nim mirror of logos-rust-sdk.
##
## Binds the language-neutral `lp_*` C ABI from logos-protocol directly (`ffi`),
## carries bytes across the JSON wire in the shared `{"_bytes": …}` form
## (`bytes`), calls other modules through a shared-per-target proxy (`plugin`),
## and exposes the linked protocol version + the instance context (`api`).
##
## `lidl-gen/` (the generator) turns a `.lidl` contract into the module's provider
## surface and a typed consumer client per dependency, on top of this runtime — so
## module code names contract methods, not this package's types.
##
## Usage (inside a Logos module):
## ```nim
## import logos_sdk
## let counter = newPluginProxy("counter_module", origin = "my_module")
## let r = counter.callSync("increment", args(%1))
## if r.ok: echo r.value
## ```

import ./logos_sdk/ffi
import ./logos_sdk/bytes
import ./logos_sdk/plugin
import ./logos_sdk/api

export ffi
export bytes
export plugin
export api
