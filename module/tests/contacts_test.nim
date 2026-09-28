## The address book store — pure/headless (json/os/tables). Persists to a temp file.

import std/[json, os, strutils]
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

block:
  # one name for a member on every surface (exo-221): the card, the approval slots and the
  # room history all ask memberLabel, whichever form the driver named the member by —
  # the 64-byte identity (0x or not, any case), "ed:" + its Ed25519 half, or an address
  var b = newContactBook(path)
  b.add(sharedId, "Bob", "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
  const edBob = "ed:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
  doAssert b.memberLabel(memberId, @[]) == "Bob" and b.memberLabel(edBob, @[]) == "Bob" and
           b.memberLabel("0xF39FD6E51AAD88F6F4CE6AB8827279CFFFB92266", @[]) == "Bob",
           "an alias names the member in every form"
  # me, in any of my forms, is "you" — before any alias
  const me = "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
  const myAddr = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  let mine = @[me, myAddr]
  doAssert b.memberLabel(me, mine) == "you" and b.memberLabel("0x" & me.toUpperAscii(), mine) == "you"
  doAssert b.memberLabel("ed:" & me[0 ..< 64], mine) == "you", "my Ed25519 half is me"
  doAssert b.memberLabel(myAddr.toLowerAscii(), mine) == "you", "my address, any case, is me"
  # a stranger: one short form, the same whichever form they were named by
  const stranger = "3d6f849ab7c0ffee00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344556677"
  let s1 = b.memberLabel(stranger, mine)
  doAssert s1 == b.memberLabel("ed:" & stranger[0 ..< 64], mine) and
           s1 == b.memberLabel("0x" & stranger.toUpperAscii(), mine), "one short form: " & s1
  doAssert s1 == "3d6f849a…", s1
  doAssert b.memberLabel("0x1234567890abcdef1234567890abcdef12345678", mine) == "0x1234…5678",
           "an unknown address keeps its 0x and both ends"
  echo "5. one name per member, whichever form a driver used: alias / you / one short id OK"

removeFile(path)
echo "contacts_test: all OK"
