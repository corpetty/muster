## Plugin sandbox (spec: contracts/specs/derived-exo-51e.spec.json,
## invariant 3, catastrophic).
##
## Plugins are pure functions from typed inputs to typed blocks. They never sign,
## never hold or read keys, never touch the network, and their only output to the
## host is a typed block — there is no plugin canvas. Two mechanisms enforce it:
##
## 1. Structural — a `Plugin` is a `{.noSideEffect.}` proc. Nim forbids a func from
##    performing IO, network, or mutable-global access at COMPILE time, so a plugin
##    physically cannot make a network call or reach key material.
## 2. Capability — the host grants plugin code exactly one operation, `opEmitBlock`.
##    Signing, key access, and network are not in the grant, so no invocation path
##    from plugin code reaches them; and host-side output validation accepts only a
##    typed block, rejecting raw markup or direct canvas calls.

type
  BlockKind* = enum
    bkText, bkAmount, bkChoice, bkFact   ## the closed typed-block vocabulary

  TypedBlock* = object
    kind*: BlockKind
    payload*: string

  # A plugin is a pure function: typed inputs → typed blocks. The `{.noSideEffect.}`
  # is the structural guarantee — such a proc cannot network, do IO, or read a
  # mutable global (where a key would have to come from).
  Plugin* = proc(inputs: seq[TypedBlock]): seq[TypedBlock] {.noSideEffect.}

  PluginOp* = enum
    opEmitBlock, opSign, opReadKey, opNetwork

  PluginGrant* = set[PluginOp]

const pluginGrant*: PluginGrant = {opEmitBlock}   ## the entire plugin capability surface

proc permitted*(op: PluginOp): bool =
  ## The host permits an operation from plugin code iff it is in the plugin grant.
  ## opSign / opReadKey / opNetwork are deliberately absent → never permitted.
  op in pluginGrant

type PluginOutput* = object
  isTypedBlock*: bool
  blk*: TypedBlock
  raw*: string        ## any non-typed output (markup, canvas/draw call)

proc acceptOutput*(o: PluginOutput): bool =
  ## Accept iff the output is a typed block and carries no raw/non-typed payload.
  o.isTypedBlock and o.raw.len == 0
