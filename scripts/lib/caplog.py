#!/usr/bin/env python3
"""A size-capped log (exo-9eed): copy stdin to PATH, and when PATH passes the cap, move it
to PATH.1 (replacing the previous one) and start a fresh PATH. At most two files, so a peer
left running for days uses at most twice the cap. A long-lived try-peer filled a disk
(573 GB) before this.

    some-command 2>&1 | python3 scripts/lib/caplog.py .run/try/alice.log [cap-MB]

The cap defaults to TRY_LOG_MB, else 64. Lines are written whole and flushed at once, so
`tail -f PATH` follows it; after a rotation, follow it again (tail -F does this itself).
"""
import os
import sys


def main() -> int:
    path = sys.argv[1]
    cap_mb = float(sys.argv[2]) if len(sys.argv) > 2 else float(os.environ.get("TRY_LOG_MB", "64"))
    cap = int(cap_mb * 1024 * 1024)
    out = open(path, "ab", buffering=0)
    size = out.tell()
    src = sys.stdin.buffer
    while True:
        line = src.readline()
        if not line:
            break
        if size + len(line) > cap and size > 0:
            out.close()
            os.replace(path, path + ".1")
            out = open(path, "ab", buffering=0)
            size = 0
        out.write(line)
        size += len(line)
    out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
