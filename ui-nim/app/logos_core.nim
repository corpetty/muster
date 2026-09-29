## The host side of logos-core for a Nim app (option B): liblogos's C API, the
## functions logos-standalone-app itself calls (its app/main.cpp), bound with importc.
## Link against the liblogos_core.so the Logos runner ships. It spawns each core
## module in a `logos_host` process, found via LOGOS_HOST_PATH or next to the
## executable.

proc logos_core_add_modules_dir*(modulesDir: cstring) {.importc, cdecl.}
proc logos_core_set_persistence_base_path*(path: cstring) {.importc, cdecl.}
proc logos_core_start*() {.importc, cdecl.}
proc logos_core_cleanup*() {.importc, cdecl.}
proc logos_core_load_module*(name: cstring, withDependencies: bool): cint {.importc, cdecl.}
proc logos_core_get_token*(key: cstring): cstring {.importc, cdecl.}
  ## The host's token for `key` (NULL if absent). The caller frees it with free().

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc hostToken*(key: string): string =
  ## The core's token for `key`, copied and freed; "" when the core has none.
  let t = logos_core_get_token(key.cstring)
  if t != nil:
    result = $t
    c_free(t)
