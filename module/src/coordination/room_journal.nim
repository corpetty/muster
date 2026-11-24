## A room's own copy on the member's machine (exo-dcc.14). Muster rebuilt a room from the
## store and the keystore alone, so the fleet's retention was the room's lifetime. Each
## member now keeps the frames it has seen, still sealed exactly as they travel, and
## rebuilds the room from them plus its keys (invariant 4: log + keys); the store becomes
## catch-up, not the only copy.
##
## What is kept: data frames (epoch-sealed events) and grant frames (each sealed whole to
## one member's X25519, so they open without any epoch key). Grants are replayed first, so
## a later epoch's data opens on replay. Beacons, join requests and invites are not the
## room's state and are not kept. Nothing is decrypted here and nothing new is stored in
## the clear: the file holds what a store node already holds.
##
## Format: records of a 4-byte little-endian length and the frame. Appended, one write per
## frame; a torn tail (a crash mid-write) reads as the frames before it.
##
## Pure Nim (os, sets, sha256) — headless-testable; the hosted module wires the path in.

import std/[os, sets]
import ../security/private_files
import ../hashing/sha256

const
  FrameData = 0x00'u8
  FrameControl = 0x02'u8
  MaxFrame = 16 * 1024 * 1024   ## a length past this is a torn or damaged record

type
  RoomJournal* = ref object
    path: string
    frames: seq[seq[byte]]
    seen: HashSet[string]

proc keyOf(frame: openArray[byte]): string =
  const d = "0123456789abcdef"
  for b in sha256(@frame): (result.add d[int(b shr 4)]; result.add d[int(b and 0x0f)])

proc openJournal*(path: string): RoomJournal =
  ## The journal at `path`: every whole record it holds, in order. A missing file is an
  ## empty journal; a damaged tail stops the read there, never a raise.
  result = RoomJournal(path: path)
  if not fileExists(path): return
  var data: string
  try: data = readFile(path)
  except CatchableError: return
  var i = 0
  while i + 4 <= data.len:
    let n = int(uint32(ord(data[i])) or (uint32(ord(data[i+1])) shl 8) or
                (uint32(ord(data[i+2])) shl 16) or (uint32(ord(data[i+3])) shl 24))
    if n <= 0 or n > MaxFrame or i + 4 + n > data.len: break
    var f = newSeq[byte](n)
    for k in 0 ..< n: f[k] = byte(ord(data[i + 4 + k]))
    let key = keyOf(f)
    if key notin result.seen:
      result.seen.incl key
      result.frames.add f
    i += 4 + n

proc record*(j: RoomJournal, frame: seq[byte]): bool =
  ## Keep `frame` if it is room state (a data or grant frame) not kept yet, appending it to
  ## the file; true when it was kept now.
  if frame.len == 0 or frame[0] notin [FrameData, FrameControl] or frame.len > MaxFrame: return false
  let key = keyOf(frame)
  if key in j.seen: return false
  j.seen.incl key
  j.frames.add frame
  try:
    let f = openPrivateAppend(j.path)
    defer: f.close()
    let n = frame.len
    var rec = newString(4 + n)
    rec[0] = char(n and 0xff); rec[1] = char((n shr 8) and 0xff)
    rec[2] = char((n shr 16) and 0xff); rec[3] = char((n shr 24) and 0xff)
    for k in 0 ..< n: rec[4 + k] = char(frame[k])
    f.write(rec)
  except CatchableError: discard        # a full disk loses the copy, never the room
  true

proc frames*(j: RoomJournal): seq[seq[byte]] = j.frames
  ## Every frame kept, in the order first seen.

proc replayOrder*(j: RoomJournal): seq[seq[byte]] =
  ## The frames in the order to replay them: grants first, so every epoch's key is held
  ## before that epoch's data is opened; then the data, in the order first seen.
  for f in j.frames:
    if f[0] == FrameControl: result.add f
  for f in j.frames:
    if f[0] == FrameData: result.add f

proc forget*(path: string) =
  ## Drop the journal (the member left the room).
  try: removeFile(path)
  except CatchableError: discard
