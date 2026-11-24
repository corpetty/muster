## Files Muster keeps beside the keystore are the member's alone (exo-863, audit P8;
## exo-3b3.16, audit P4-02 / P4-03).
##
## The keyfile, the real LEZ wallet, the room list, room titles, contacts, settings (a Bitcoin
## node URL may carry its RPC credentials), the split book, dismissed invites and each room's
## journal say who a member is, which rooms they are in and what they are paying. They were
## written with the process umask, which on a typical host lets every other account read them,
## and the keyfile was chmod-ed only after it was written, the failure ignored. Here:
##
##   writePrivateFile — a temp file beside the target with an unguessable name, created
##     O_CREAT|O_EXCL at 0600 (never through an existing name or a planted link), its mode
##     checked before a byte is written, fsync'd, renamed over the target, and the directory
##     fsync'd: a crash leaves the old contents or the new, never half of either; a mode that
##     cannot be set refuses the write.
##   openPrivateAppend — a file opened for appending, created 0600 or narrowed to it, never
##     through a link.
##   ensurePrivateDir — a folder made for these files is 0700; an existing one is left as it
##     is (it may be the host's per-instance folder).
##   ensureOwnPrivateDir — a folder that holds secrets of its own (the LEZ wallet): 0700,
##     created or narrowed, and refused when it is a link, belongs to another user, or sits
##     in a folder that does (root excepted, as for /tmp).
##
## Pure, no module state: headless-testable (private_files_test).

import std/[os, strutils, times]
when defined(posix):
  import std/posix
  proc c_rename(a, b: cstring): cint {.importc: "rename", header: "<stdio.h>".}
  var O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint

type PrivateFileError* = object of IOError

proc fail(msg: string) {.noreturn.} =
  raise newException(PrivateFileError, msg)

const OwnerOnlyDir = {fpUserRead, fpUserWrite, fpUserExec}

proc ensurePrivateDir*(dir: string) =
  ## Create `dir` (and any missing parents) if it is not there. The directory created here
  ## is owner-only; an existing directory is left as it is: it may be the host's.
  if dir.len == 0 or dirExists(dir): return
  createDir(dir)
  when defined(posix): setFilePermissions(dir, OwnerOnlyDir)

proc dirOwnedByMe*(dir: string): bool =
  ## True when `dir` exists and belongs to this process's user. A fallback directory under
  ## a shared temporary directory may already have been made by someone else.
  when defined(posix):
    var st: Stat
    if stat(dir.cstring, st) != 0: return false
    st.st_uid == geteuid()
  else:
    dirExists(dir)

when defined(posix):
  proc ownerOk(st: Stat, allowRoot: bool): bool =
    st.st_uid == geteuid() or (allowRoot and st.st_uid == 0.Uid)

  proc randomSuffix(): string =
    ## 8 random bytes as hex: the name only has to be unguessable; O_EXCL refuses one that
    ## exists anyway.
    var b: array[8, byte]
    var f: File
    if open(f, "/dev/urandom"):
      try: discard f.readBuffer(addr b[0], b.len)
      finally: f.close()
    else:
      let t = getCurrentProcessId() xor int(epochTime() * 1e6)
      for i in 0 ..< 8: b[i] = byte((t shr (i * 8)) and 0xff)
    for x in b: result.add toHex(x.int, 2).toLowerAscii()

proc ensureOwnPrivateDir*(path: string) =
  ## `path` as a folder only this user can enter: created at 0700 when missing, set to 0700
  ## when it exists. Refused (raises) when it is not a folder, is a symbolic link, belongs to
  ## another user, or sits in a folder that belongs to another user (root excepted, as for
  ## /tmp); its mode is checked after the change, and a folder still open to others is refused.
  if path.len == 0: fail("no folder named")
  when defined(posix):
    let parent = parentDir(path)
    if parent.len > 0:
      if not dirExists(parent): ensurePrivateDir(parent)
      var ps: Stat
      if lstat(parent.cstring, ps) != 0: fail("cannot read " & parent & ": " & $strerror(errno))
      if not ownerOk(ps, allowRoot = true):
        fail("refusing " & path & ": the folder holding it, " & parent & ", belongs to another user")
    var st: Stat
    if lstat(path.cstring, st) != 0:
      if errno != ENOENT: fail("cannot read " & path & ": " & $strerror(errno))
      if mkdir(path.cstring, 0o700.Mode) != 0 and errno != EEXIST:
        fail("cannot create " & path & ": " & $strerror(errno))
      if lstat(path.cstring, st) != 0: fail("cannot read " & path & ": " & $strerror(errno))
    if S_ISLNK(st.st_mode): fail("refusing " & path & ": it is a symbolic link")
    if not S_ISDIR(st.st_mode): fail("refusing " & path & ": it is not a folder")
    if not ownerOk(st, allowRoot = false):
      fail("refusing " & path & ": it belongs to another user")
    if (st.st_mode.cint and 0o777) != 0o700:
      if chmod(path.cstring, 0o700.Mode) != 0:
        fail("cannot make " & path & " private: " & $strerror(errno))
      if lstat(path.cstring, st) != 0 or (st.st_mode.cint and 0o077) != 0:
        fail("refusing " & path & ": its mode could not be set to 0700")
  else:
    createDir(path)

proc writePrivateFile*(path: string, data: openArray[byte]) =
  ## Replace `path` with `data`, readable by this user alone from its first byte, all or
  ## nothing. Raises PrivateFileError and leaves `path` as it was when any step fails.
  if path.len == 0: fail("no file named")
  let dir = parentDir(path)
  ensurePrivateDir(dir)
  when defined(posix):
    let tmp = path & ".tmp-" & randomSuffix()
    let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, 0o600.Mode)
    if fd < 0: fail("cannot create " & tmp & ": " & $strerror(errno))
    var ok, closed = false
    try:
      # The umask can only narrow 0600; set it exactly and check, before anything is written.
      if fchmod(fd, 0o600.Mode) != 0: fail("cannot set the mode of " & tmp & ": " & $strerror(errno))
      var st: Stat
      if fstat(fd, st) != 0: fail("cannot read " & tmp & ": " & $strerror(errno))
      if (st.st_mode.cint and 0o777) != 0o600 or st.st_uid != geteuid():
        fail("refusing to write " & path & ": its mode could not be set to 0600")
      var off = 0
      while off < data.len:
        let n = posix.write(fd, unsafeAddr data[off], data.len - off)
        if n < 0:
          if errno == EINTR: continue
          fail("cannot write " & tmp & ": " & $strerror(errno))
        off += n
      if fsync(fd) != 0: fail("cannot sync " & tmp & ": " & $strerror(errno))
      closed = true
      if posix.close(fd) != 0: fail("cannot close " & tmp & ": " & $strerror(errno))
      if c_rename(tmp.cstring, path.cstring) != 0:
        fail("cannot replace " & path & ": " & $strerror(errno))
      ok = true
    finally:
      if not ok:
        if not closed: discard posix.close(fd)
        discard unlink(tmp.cstring)
    # the rename is durable once its directory is
    let dfd = posix.open((if dir.len > 0: dir else: ".").cstring, O_RDONLY or O_CLOEXEC)
    if dfd >= 0:
      discard fsync(dfd)
      discard posix.close(dfd)
  else:
    var s = newString(data.len)
    for i in 0 ..< data.len: s[i] = char(data[i])
    writeFile(path, s)

proc writePrivateFile*(path, data: string) =
  ## Replace `path` with `data`, owner-only, all or nothing.
  writePrivateFile(path, data.toOpenArrayByte(0, data.high))

proc openPrivateAppend*(path: string): File =
  ## `path` opened for appending, created owner-only (or narrowed to it) first; never
  ## through a link planted at `path`.
  ensurePrivateDir(parentDir(path))
  when defined(posix):
    let fd = posix.open(path.cstring,
                        O_WRONLY or O_CREAT or O_APPEND or O_NOFOLLOW or O_CLOEXEC, 0o600.Mode)
    if fd < 0: fail("cannot open " & path & ": " & $strerror(errno))
    if fchmod(fd, 0o600.Mode) != 0:     # an existing file an older build left readable
      let msg = $strerror(errno)
      discard posix.close(fd)
      fail("cannot set the mode of " & path & ": " & msg)
    if not open(result, FileHandle(fd), fmAppend):
      discard posix.close(fd)
      fail("cannot open for append: " & path)
  else:
    result = open(path, fmAppend)

proc fileMode*(path: string): int =
  ## The permission bits of `path` (for tests and checks); -1 when it cannot be read.
  when defined(posix):
    var st: Stat
    if stat(path.cstring, st) != 0: return -1
    int(st.st_mode.cint and 0o777)
  else:
    -1
