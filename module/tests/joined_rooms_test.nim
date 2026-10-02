## The rooms this member joined, persisted beside the keystore (exo-ecbe) — pure/headless
## (json/os). A relaunched member's Home listed nothing: the module kept its rooms only in
## memory, so a restart lost every one and the only way back was typing the topic.

import std/[os]
import ../src/coordination/joined_rooms

let dir = getTempDir() / ("muster-joined-rooms-test-" & $getCurrentProcessId())
let path = dir / "joined_rooms.json"
removeDir(dir)

const roomA = "/muster/1/muster.room.6ac8ea9cdc366149/proto"
const roomB = "/muster/1/muster.room.0123456789abcdef/proto"

block:
  doAssert loadJoinedRooms(path).len == 0, "no file yet: no rooms"
  doAssert rememberJoinedRoom(path, roomA), "a first join is remembered"
  doAssert fileExists(path), "remembering creates the file, and its directory"
  doAssert rememberJoinedRoom(path, roomB)
  doAssert not rememberJoinedRoom(path, roomA), "joining a room again adds nothing"
  doAssert loadJoinedRooms(path) == @[roomA, roomB], "one entry per room, in join order"
  echo "1. remember: once per room, in join order, created on first join OK"

block:
  # a relaunch reads the same file afresh
  doAssert loadJoinedRooms(path) == @[roomA, roomB], "the rooms survive a relaunch"
  doAssert not rememberJoinedRoom(path, ""), "an empty topic is never a room"
  doAssert loadJoinedRooms(path) == @[roomA, roomB]
  echo "2. a relaunch reads every room back OK"

block:
  # a damaged file never raises and never reads as rooms; the next join rewrites it whole
  writeFile(path, "{not json")
  doAssert loadJoinedRooms(path).len == 0, "a malformed file reads as no rooms, never a raise"
  writeFile(path, """["""" & roomA & """", 7, null, ""]""")
  doAssert loadJoinedRooms(path) == @[roomA], "only non-empty strings are rooms"
  doAssert rememberJoinedRoom(path, roomB)
  doAssert loadJoinedRooms(path) == @[roomA, roomB], "the next join rewrites the file clean"
  echo "3. a damaged file reads as what it validly holds OK"

removeDir(dir)
echo "joined_rooms_test: all OK"
