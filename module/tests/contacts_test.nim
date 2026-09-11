## The address book store — pure/headless (json/os/tables). Persists to a temp file.

import std/[json, os]
import ../src/coordination/contacts

let path = getTempDir() / "muster-contacts-test.json"
removeFile(path)

# a member id as coordinate_members emits it (0x + 128 hex); a shared chat id as the
# Settings copy button produces it (128 hex, no 0x) — must resolve to the SAME contact.
const memberId = "0xAABBccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
const sharedId = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"

block:
  var b = newContactBook(path)
  doAssert b.asJson().len == 0, "a fresh book is empty"

  # add from the shared id (no 0x, mixed handled), then resolve from the member id (0x)
  b.add(sharedId, "Alice", "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
  doAssert b.aliasOf(memberId) == "Alice", "member id (0x + uppercase) resolves to the contact added by shared id"
  doAssert b.aliasOf(sharedId) == "Alice"
  doAssert b.asJson().len == 1
  echo "1. add + normalized resolution (0x/case-insensitive) OK"

  # rename; add merge does not clobber a stored alias with an empty one
  b.setAlias(sharedId, "Alice Cooper")
  doAssert b.aliasOf(memberId) == "Alice Cooper", "rename sticks"
  b.add(memberId, "", "0xdeadbeef")   # empty alias must not wipe the name
  doAssert b.aliasOf(memberId) == "Alice Cooper", "empty alias on add does not clobber"
  let j = b.asJson()
  doAssert j[0]["address"].getStr() == "0xdeadbeef", "address filled in by the merging add"
  echo "2. rename + merging add (no clobber) OK"

block:
  # persistence: a new book over the same path sees the stored contact
  let b2 = newContactBook(path)
  doAssert b2.aliasOf(memberId) == "Alice Cooper", "the book persisted across instances"
  echo "3. persistence across instances OK"

block:
  var b = newContactBook(path)
  b.remove(sharedId)
  doAssert b.aliasOf(memberId) == "", "removed contact no longer resolves"
  doAssert b.asJson().len == 0
  echo "4. remove OK"

removeFile(path)
echo "contacts_test: all OK"
