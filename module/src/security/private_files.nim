## Files Muster keeps beside the keystore are the member's alone (exo-863, audit P8).
##
## The room list, room titles, contacts, settings (a Bitcoin node URL may carry its RPC
## credentials), the split book, dismissed invites and each room's journal say which rooms
## a member is in, who their contacts are and what they are paying. They were written with
## the process umask, which on a typical host lets every other account read them. Here each
## is created owner-only (0600) from its first byte, never written readable and narrowed
## after; a directory made for one is 0700; a file an older build left readable is narrowed
## the next time it is written.
##
## A whole-file write goes to a temporary file and is renamed over the old one, so a crash
## mid-write leaves the previous contents, never half of the new.

import std/os
when defined(posix): import std/posix

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
    st.st_uid == getuid()
  else:
    dirExists(dir)

when defined(posix):
  proc openOwnerOnly(path: string, flags: cint): cint =
    result = posix.open(path.cstring, flags or O_WRONLY or O_CREAT, Mode(0o600))
    if result < 0: raiseOSError(osLastError(), path)
    if fchmod(result, Mode(0o600)) != 0:     # an existing file an older build left readable
      let err = osLastError()
      discard posix.close(result)
      raiseOSError(err, path)

proc writePrivateFile*(path, data: string) =
  ## Replace `path` with `data`, owner-only.
  ensurePrivateDir(parentDir(path))
  when defined(posix):
    let tmp = path & ".tmp"
    let fd = openOwnerOnly(tmp, O_TRUNC)
    var off = 0
    while off < data.len:
      let n = posix.write(fd, unsafeAddr data[off], data.len - off)
      if n < 0:
        let err = osLastError()
        discard posix.close(fd)
        raiseOSError(err, tmp)
      off += n
    if posix.close(fd) != 0: raiseOSError(osLastError(), tmp)
    moveFile(tmp, path)
  else:
    writeFile(path, data)

proc openPrivateAppend*(path: string): File =
  ## `path` opened for appending, created owner-only (or narrowed to it) first.
  ensurePrivateDir(parentDir(path))
  when defined(posix):
    let fd = openOwnerOnly(path, O_APPEND)
    if not open(result, FileHandle(fd), fmAppend):
      discard posix.close(fd)
      raise newException(IOError, "cannot open for append: " & path)
  else:
    result = open(path, fmAppend)
