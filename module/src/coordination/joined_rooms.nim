## The rooms this member has joined (exo-ecbe) — a JSON array of content topics, in join
## order, persisted beside the keystore so a relaunch re-enters every one. Without it the
## joined set lived only in memory: a restart left Home empty, and the only way back was
## typing the topic. Nothing else is kept here: a room's state is reduce(log), rebuilt
## from the store and the keystore when the module re-enters it.
##
## Pure Nim (json/os) — headless-testable; the module wires the path in. A missing or
## damaged file reads as the rooms it validly holds, never as a raise.

import std/[json, os]

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

proc rememberJoinedRoom*(path, ctopic: string): bool =
  ## Add `ctopic` to the rooms at `path` and persist; true when it was not there yet.
  ## Rewrites the file whole, so a damaged one comes back clean.
  if ctopic.len == 0: return false
  var rooms = loadJoinedRooms(path)
  if ctopic in rooms: return false
  rooms.add ctopic
  try:
    createDir(parentDir(path))
    var arr = newJArray()
    for t in rooms: arr.add %t
    writeFile(path, $arr)
  except CatchableError: discard
  true
