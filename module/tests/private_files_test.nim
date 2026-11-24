## Files kept beside the keystore are the member's alone (exo-863, audit P8; exo-3b3.16, audit
## P4-02 / P4-03). Room lists, contacts, settings (a Bitcoin node URL may carry its RPC
## credentials), the split book and the room journal were written with the process umask, so
## on a typical 022 host every other account on the machine could read which rooms a member is
## in and who their contacts are; the keyfile was written under the umask and chmod-ed after,
## the failure ignored, in place. Each is now created owner-only from its first byte and
## replaced all or nothing, never written through a planted link; a file an older build left
## world-readable is narrowed the next time it is written; the real LEZ wallet's folder is
## 0700 and refused when it is a link or someone else's.
## Needs libsecp256k1 + libsodium (the keystore half; see tests/README.md).

import std/[os, posix, strutils]
import ../src/security/private_files
import ../src/crypto/keystore
import ../src/crypto/sodium
import ../src/coordination/[joined_rooms, contacts, room_journal]

let root = getTempDir() / ("muster-private-files-test-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc noTempLeft(dir: string) =
  for f in walkDir(dir):
    doAssert ".tmp" notin f.path, "a temporary file was left behind: " & f.path

# Under a umask that would leave a new file open to everyone.
discard umask(0o000.Mode)

block:
  let p = root / "fresh" / "settings.json"
  writePrivateFile(p, """{"btcRpc":"http://user:secret@127.0.0.1:8332"}""")
  doAssert readFile(p) == """{"btcRpc":"http://user:secret@127.0.0.1:8332"}"""
  doAssert fileMode(p) == 0o600, "a new file is owner-only, got " & toOct(fileMode(p), 3)
  doAssert fileMode(root / "fresh") == 0o700, "a directory made for it is owner-only"
  noTempLeft(root / "fresh")
  writePrivateFile(p, "")
  doAssert readFile(p) == "", "an empty write empties the file"
  echo "1. a new file and its new directory are owner-only under umask 000, no temp left OK"

block:
  let p = root / "old" / "contacts.json"
  createDir(parentDir(p))
  writeFile(p, "left by an older build")
  setFilePermissions(p, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  doAssert fileMode(p) == 0o644
  writePrivateFile(p, "{}")
  doAssert readFile(p) == "{}" and fileMode(p) == 0o600,
    "a world-readable file from an older build is narrowed on its next write"
  echo "2. an older world-readable file is narrowed when written OK"

block:
  let p = root / "old" / "journal.bin"
  writeFile(p, "ab")
  setFilePermissions(p, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  let f = openPrivateAppend(p)
  f.write("cd")
  f.close()
  doAssert readFile(p) == "abcd", "append keeps what was there"
  doAssert fileMode(p) == 0o600, "an appended file is narrowed too"
  let q = root / "new" / "journal.bin"
  let g = openPrivateAppend(q)
  g.write("x")
  g.close()
  doAssert fileMode(q) == 0o600 and fileMode(root / "new") == 0o700
  # never through a link planted where the journal goes
  let elsewhere = root / "append-target"
  let linked = root / "new" / "linked.bin"
  createSymlink(elsewhere, linked)
  var raised = false
  try: discard openPrivateAppend(linked)
  except PrivateFileError: raised = true
  doAssert raised and not fileExists(elsewhere), "an append through a planted link is refused"
  echo "3. append: created and narrowed owner-only, never through a link OK"

block:
  doAssert dirOwnedByMe(root)
  if getuid() != 0:
    doAssert not dirOwnedByMe("/"), "a directory someone else owns is refused"
  echo "4. ownership of a shared fallback directory is checked OK"

block:
  # the stores that call it: each file they keep is owner-only
  let d = root / "stores"
  doAssert rememberJoinedRoom(d / "joined_rooms.json", "/muster/1/muster.room.0123456789abcdef/proto")
  doAssert fileMode(d / "joined_rooms.json") == 0o600, "joined rooms"
  doAssert setRoomTitle(d / "room_titles.json", "/muster/1/muster.room.0123456789abcdef/proto", "rent")
  doAssert fileMode(d / "room_titles.json") == 0o600, "room titles"
  let book = newContactBook(d / "contacts.json")
  book.add(repeat('a', 128), "ana")
  doAssert fileMode(d / "contacts.json") == 0o600, "contacts"
  let j = openJournal(d / "journals" / "room.bin")
  doAssert j.record(@[0x00'u8, 1, 2, 3])          # a data frame
  doAssert fileMode(d / "journals" / "room.bin") == 0o600, "room journal"
  echo "5. joined rooms, titles, contacts and the journal are kept owner-only OK"

block:
  # All or nothing: when the replace cannot happen (the target is a folder), the target is
  # unchanged and no temp file is left.
  let p = root / "c"
  createDir(p)
  var raised = false
  try: writePrivateFile(p, "x")
  except PrivateFileError: raised = true
  doAssert raised, "a replace that cannot happen raises"
  doAssert dirExists(p)
  noTempLeft(root)
  echo "6. a failed replace raises and leaves nothing behind OK"

block:
  # A link planted where the keyfile goes is replaced, never written through: the keyfile
  # never lands at the place the link names.
  let dir = root / "ks"
  createDir(dir)
  let elsewhere = root / "planted-target.mks"
  let path = dir / "identity.mks"
  createSymlink(elsewhere, path)               # dangling: names a file that does not exist
  let ks = openFileKeystore(path, "pass one")
  doAssert not fileExists(elsewhere), "the keyfile was written through a planted link"
  doAssert not symlinkExists(path), "the link was left in place of the keyfile"
  doAssert fileMode(path) == 0o600
  doAssert openFileKeystore(path, "pass one").address() == ks.address()
  noTempLeft(dir)
  echo "7. a planted link is replaced, not written through; the keyfile is 0600 OK"

block:
  # A v1 keyfile (secp secret only) upgrades in place to v2 atomically: same address, 0600.
  let path = root / "v1.mks"
  var secret: array[32, byte]
  for i in 0 ..< 32: secret[i] = byte(i + 1)
  let salt = randomBytes(PwSaltBytes)
  var s: array[PwSaltBytes, byte]
  for i in 0 ..< PwSaltBytes: s[i] = salt[i]
  let sealed = secretboxSeal(pwhashKey("pw", s), @secret)
  var blob = @[byte 'M', byte 'K', byte 'S', 1'u8]
  blob.add salt
  blob.add sealed
  var raw = newString(blob.len)
  for i in 0 ..< blob.len: raw[i] = char(blob[i])
  writeFile(path, raw)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  let a = openFileKeystore(path, "pw")
  doAssert readFile(path)[3] == char(2), "upgraded to v2"
  doAssert fileMode(path) == 0o600, "the upgraded keyfile is 0600"
  let b = openFileKeystore(path, "pw")
  doAssert a.address() == b.address() and a.encIdentity() == b.encIdentity()
  echo "8. a v1 keyfile upgrades to v2 atomically, 0600, identity kept OK"

block:
  # A folder holding secrets of its own (the LEZ wallet): created 0700; an existing 0755 one
  # is narrowed to 0700.
  let d = root / "lez"
  ensureOwnPrivateDir(d)
  doAssert dirExists(d) and fileMode(d) == 0o700
  let e = root / "open"
  createDir(e)
  setFilePermissions(e, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
                         fpOthersRead, fpOthersExec})
  ensureOwnPrivateDir(e)
  doAssert fileMode(e) == 0o700
  echo "9. a wallet folder is 0700, created or narrowed OK"

block:
  # A link in place of the wallet folder is refused (it names somewhere someone else chose).
  let target = root / "link-target"
  createDir(target)
  let d = root / "linked"
  createSymlink(target, d)
  var raised = false
  try: ensureOwnPrivateDir(d)
  except PrivateFileError: raised = true
  doAssert raised, "a link in place of the wallet folder is refused"
  echo "10. a link in place of the wallet folder is refused OK"

block:
  # A folder that belongs to another user is refused. Root-owned /proc is a folder any test
  # can name that is not ours. (Skipped as root, who owns it.)
  if geteuid() != 0.Uid:
    var raised = false
    try: ensureOwnPrivateDir("/proc")
    except PrivateFileError as e:
      raised = "another user" in e.msg
    doAssert raised, "a folder that belongs to another user is refused"
    echo "11. a wallet folder owned by another user is refused OK"
  else:
    echo "11. skipped (running as root)"

removeDir(root)
echo "private_files_test: all OK"
