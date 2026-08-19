## Muster module impl — the P0 loading-spike surface.
##
## Mirrors logos-rust-sdk's provider `lib.rs`: include the generated module-impl
## surface, then define the author methods it forwards to. The staticlib is
## compiled from this file (`nim c --app:staticlib --noMain`), producing
## `libmuster_module.a`, whose `logos_module_*` exports the generated C++ plugin
## glue links against.
##
## These two methods exist only to prove a Nim-authored module loads and answers
## a call in logoscore. The real coordination surface grows from muster.lidl at
## P1; when the B4 Nim lidl-gen lands, `muster_gen.nim` is regenerated and these
## bodies become the impl behind the generated trait.

include muster_gen

proc musterHealth(): string =
  ## Liveness probe: proves a no-argument call reaches the Nim backend.
  "ok"

proc musterEcho(msg: string): string =
  ## Round-trips a value caller -> Nim -> caller across the LIDL surface.
  msg
