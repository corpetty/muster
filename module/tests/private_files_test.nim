## Files kept beside the keystore are the member's alone (exo-863, audit P8). Room lists,
## contacts, settings (a Bitcoin node URL may carry its RPC credentials), the split book and
## the room journal were written with the process umask, so on a typical 022 host every
## other account on the machine could read which rooms a member is in and who their
## contacts are. Each is now created owner-only from its first byte, and a file an older
## build left world-readable is narrowed the next time it is written.

import std/[os, posix, strutils]
import ../src/security/private_files
import ../src/coordination/[joined_rooms, contacts, room_journal]

proc modeOf(path: string): int =
  var st: Stat
  doAssert stat(path.cstring, st) == 0, "stat " & path
  int(st.st_mode) and 0o777

discard umask(Mode(0o022))     # the common default: what an unguarded write would get
let root = getTempDir() / ("muster-private-files-test-" & $getCurrentProcessId())
removeDir(root)

block:
  let p = root / "fresh" / "settings.json"
  writePrivateFile(p, """{"btcRpc":"http://user:secret@127.0.0.1:8332"}""")
  doAssert readFile(p) == """{"btcRpc":"http://user:secret@127.0.0.1:8332"}"""
  doAssert modeOf(p) == 0o600, "a new file is owner-only, got " & $modeOf(p).toOct(3)
  doAssert modeOf(root / "fresh") == 0o700, "a directory made for it is owner-only"
  doAssert not fileExists(p & ".tmp"), "no temporary file is left behind"
  writePrivateFile(p, "")
  doAssert readFile(p) == "", "an empty write empties the file"
  echo "1. a new file and its new directory are owner-only OK"

block:
  let p = root / "old" / "contacts.json"
  createDir(parentDir(p))
  writeFile(p, "left by an older build")
  setFilePermissions(p, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  doAssert modeOf(p) == 0o644
  writePrivateFile(p, "{}")
  doAssert modeOf(p) == 0o600, "a world-readable file from an older build is narrowed on its next write"
  echo "2. an older world-readable file is narrowed when written OK"

block:
  let p = root / "old" / "journal.bin"
  writeFile(p, "ab")
  setFilePermissions(p, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  let f = openPrivateAppend(p)
  f.write("cd")
  f.close()
  doAssert readFile(p) == "abcd", "append keeps what was there"
  doAssert modeOf(p) == 0o600, "an appended file is narrowed too"
  let q = root / "new" / "journal.bin"
  let g = openPrivateAppend(q)
  g.write("x")
  g.close()
  doAssert modeOf(q) == 0o600 and modeOf(root / "new") == 0o700
  echo "3. append: created and narrowed owner-only OK"

block:
  doAssert dirOwnedByMe(root)
  if getuid() != 0:
    doAssert not dirOwnedByMe("/"), "a directory someone else owns is refused"
  echo "4. ownership of a shared fallback directory is checked OK"

block:
  # the stores that call it: each file they keep is owner-only
  let d = root / "stores"
  doAssert rememberJoinedRoom(d / "joined_rooms.json", "/muster/1/muster.room.0123456789abcdef/proto")
  doAssert modeOf(d / "joined_rooms.json") == 0o600, "joined rooms"
  doAssert setRoomTitle(d / "room_titles.json", "/muster/1/muster.room.0123456789abcdef/proto", "rent")
  doAssert modeOf(d / "room_titles.json") == 0o600, "room titles"
  let book = newContactBook(d / "contacts.json")
  book.add(repeat('a', 128), "ana")
  doAssert modeOf(d / "contacts.json") == 0o600, "contacts"
  let j = openJournal(d / "journals" / "room.bin")
  doAssert j.record(@[0x00'u8, 1, 2, 3])          # a data frame
  doAssert modeOf(d / "journals" / "room.bin") == 0o600, "room journal"
  echo "5. joined rooms, titles, contacts and the journal are kept owner-only OK"

removeDir(root)
echo "private_files_test: all OK"
