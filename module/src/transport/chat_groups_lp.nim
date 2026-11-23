## The platform half of transport/chat_groups.nim (exo-7a5): `chat_module` over lp_*. Not pure,
## so it is compiled only into the plugin. Muster calls the module raw, as `muster_module`.
##
## `init` once, on the fleet muster's own delivery node runs (the chat module adopts that node:
## a node that already exists keeps its preset, chat_module.lidl `ChatConfig`). Every call is one
## bounded lp_invoke on the intents tick; the chat module answers from its own state, never from
## the network, so none waits on delivery. A `result` reply is read as `{success, value, error}`
## or as the bare value; a refusal raises `ChatError` with the module's words.
##
## `remove_group_member` is not in the published chat_module (0.3.0). Until it is, removeMember
## raises, and the planner's removals are reported as failed rather than silently skipped.

import std/json
import logos_sdk/ffi
import ./chat_groups

const
  ChatModule* = "chat_module"
  Ours = "muster_module"
  CallMs = 5_000.cint

type LpChatGroups* = ref object of ChatGroups
  client: ptr LpClient
  preset: string
  inited: bool
  myAddr: string

proc newLpChatGroups*(preset: string): LpChatGroups =
  result = LpChatGroups(preset: preset)
  GC_ref(result)

proc reached(c: LpChatGroups): bool =
  if c.client == nil:
    c.client = lp_client_create(ChatModule.cstring, Ours.cstring, nil, nil)
  c.client != nil

proc call(c: LpChatGroups, meth: string, args: JsonNode): JsonNode =
  if not c.reached(): raise newException(ChatError, "chat_module is not loaded")
  var res, err: cstring
  let rc = lp_invoke(c.client, meth.cstring, ($args).cstring, CallMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil:
    raise newException(ChatError, "chat_module." & meth & ": " & (if err != nil: $err else: "no answer"))
  try: result = parseJson($res)
  except CatchableError: result = newJString($res)

proc value(meth: string, j: JsonNode): JsonNode =
  ## A `result` reply: {success, value, error}, or the bare value.
  if j.kind == JObject and j.hasKey("success"):
    if not j["success"].getBool():
      raise newException(ChatError, "chat_module." & meth & " refused: " & j{"error"}.getStr(j{"value"}.getStr("")))
    return j{"value"}
  j

proc init(c: LpChatGroups) =
  if c.inited: return
  discard value("init", c.call("init", %*[{"delivery_preset": c.preset}]))
  c.inited = true

method ready*(c: LpChatGroups): bool =
  try:
    c.init()
    true
  except CatchableError: false

method address*(c: LpChatGroups): string =
  if c.myAddr.len == 0:
    c.init()
    c.myAddr = value("get_address", c.call("get_address", %*[])).getStr()
  c.myAddr

method createGroup*(c: LpChatGroups, name, desc: string): string =
  c.init()
  value("create_group_conversation", c.call("create_group_conversation", %*[name, desc])).getStr()

method addMember*(c: LpChatGroups, convo, address: string) =
  c.init()
  discard value("add_group_member", c.call("add_group_member", %*[convo, address]))

method removeMember*(c: LpChatGroups, convo, address: string) =
  c.init()
  discard value("remove_group_member", c.call("remove_group_member", %*[convo, address]))

method members*(c: LpChatGroups, convo: string): seq[ChatMember] =
  c.init()
  let j = value("list_group_members", c.call("list_group_members", %*[convo]))
  if j.kind != JArray: return
  for m in j:
    let a = m{"address"}.getStr()
    if a.len > 0: result.add ChatMember(address: a, pending: m{"pending"}.getBool(false))
