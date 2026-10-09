## The rooms this member has joined (exo-ecbe) — a JSON array of content topics, in join
## order, persisted beside the keystore so a relaunch re-enters every one. Without it the
## joined set lived only in memory: a restart left Home empty, and the only way back was
## typing the topic. Nothing else is kept here: a room's state is reduce(log), rebuilt
## from the store and the keystore when the module re-enters it.
##
## Pure Nim (json/os) — headless-testable; the module wires the path in. A missing or
## damaged file reads as the rooms it validly holds, never as a raise.

import std/[json, os, tables]
export tables

proc loadJoinedRooms*(path: string): seq[string] =
  ## Every room remembered at `path`, in join order: its non-empty string entries.
  try:
    if not fileExists(path): return
    let j = parseJson(readFile(path))
    if j.kind != JArray: return
    for x in j:
      if x.kind == JString and x.getStr().len > 0 and x.getStr() notin result:
        result.add x.getStr()
  except CatchableError: discard

proc writeRooms(path: string, rooms: seq[string]) =
  try:
    createDir(parentDir(path))
    var arr = newJArray()
    for t in rooms: arr.add %t
    writeFile(path, $arr)
  except CatchableError: discard

proc rememberJoinedRoom*(path, ctopic: string): bool =
  ## Add `ctopic` to the rooms at `path` and persist; true when it was not there yet.
  ## Rewrites the file whole, so a damaged one comes back clean.
  if ctopic.len == 0: return false
  var rooms = loadJoinedRooms(path)
  if ctopic in rooms: return false
  rooms.add ctopic
  writeRooms(path, rooms)
  true

proc forgetJoinedRoom*(path, ctopic: string): bool =
  ## Drop `ctopic` from the rooms at `path` (exo-dcc.28: the member left it), so a
  ## relaunch no longer re-enters it; true when it was there. The rest keep their order.
  var rooms = loadJoinedRooms(path)
  let i = rooms.find(ctopic)
  if i < 0: return false
  rooms.delete(i)
  writeRooms(path, rooms)
  true

# ── room names (exo-dcc.25) ────────────────────────────────────────────────────
# A room's topic names nothing (exo-661.7), so a member names the room for themselves.
# The name is this member's own label, kept in its own file beside the rooms (whose
# format stays a plain array of topics); it never goes to the room or the wire.

proc loadRoomTitles*(path: string): Table[string, string] =
  ## Every room name at `path`, by content topic. A missing or damaged file reads as
  ## the names it validly holds, never a raise.
  try:
    if not fileExists(path): return
    let j = parseJson(readFile(path))
    if j.kind != JObject: return
    for k, v in j:
      if k.len > 0 and v.kind == JString and v.getStr().len > 0: result[k] = v.getStr()
  except CatchableError: discard

proc setRoomTitle*(path, ctopic, title: string): bool =
  ## Name the room at `ctopic` (an empty title clears its name) and persist; false
  ## only for an empty topic. Rewrites the file whole, so a damaged one comes back clean.
  if ctopic.len == 0: return false
  var titles = loadRoomTitles(path)
  if title.len == 0: titles.del ctopic
  else: titles[ctopic] = title
  try:
    createDir(parentDir(path))
    var obj = newJObject()
    for k, v in titles: obj[k] = %v
    writeFile(path, $obj)
  except CatchableError: discard
  true
