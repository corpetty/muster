#!/usr/bin/env python3
"""A runner's log with the UI plugin's lines as the plugin wrote them, one to a line.

    python3 -I scripts/lib/ui_log.py <log>      (the self-tests call it as `ui_log <log>`)

The C++ UI's own lines (its `[muster_ui] …` qInfo) do not reach the log bare. Read off the
standalone runner's logs on Linux CI (run 39836679442: four logs, about 7,000 relayed lines
each, every other line bare):

1. ui-host relays the plugin's output a chunk at a time, each chunk ONE line, QDebug-quoted
   as a byte string, with the chunk's last newline trimmed:
       ui-host [ "muster_ui" ]: "[muster_ui] VOICE {\\"playing\\":null}\\n[muster_ui] VOICE-NOTES []"
   Escapes \\" \\\\ \\n \\t \\r \\b \\f, \\xHH for any other byte (so UTF-8 arrives as
   \\xE2\\x80\\xA6), and "" after a \\xHH when a hex digit follows. A chunk often holds
   several of the plugin's lines.
2. The plugin's lines reach ui-host 128 bytes at a time, so a chunk can end inside one of
   them, and the next chunk of that plugin goes on with it. When it does, that line is a
   whole number of 128 bytes long so far, unquoted (906 of 908 cuts in the four logs); a
   chunk's last line that is whole almost never is (1 of 27,500). So such a line is joined to
   the first line of the plugin's next chunk.
3. The relayed line is written 128 bytes at a time too, and the runner's other processes
   write to the same log: now and then one of their lines (always timestamped, as
   [2026-10-22 19:26:28.980] [info] …) lands after a piece. The physical line then ends with
   that line, and the chunk's rest is the very next line, with no prefix but with the closing
   quote. The cut can fall anywhere: inside a [muster_ui] line, inside an escape (\\ | n).
   So an open chunk is cut at that line's timestamp and joined with the next line, and the
   other process's line is printed after the chunk's lines written before it.

Every other line (the module hosts', and the Nim UI's, which writes its lines bare) is
printed unchanged. What it prints is valid UTF-8 (a byte that is not: U+FFFD). It never
raises on what the log holds; a log it cannot open is an empty one.
"""
import re
import sys

PREFIX = re.compile(rb'^ui-host \[ "([^"]*)" \]: "')
STAMP = re.compile(rb"\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}\] \[")
PIECE = 128
SIMPLE = {ord('"'): b'"', ord("\\"): b"\\", ord("t"): b"\t", ord("r"): b"\r", ord("b"): b"\b",
          ord("f"): b"\f", ord("a"): b"\a", ord("v"): b"\v", ord("0"): b"\0"}
HEX = b"0123456789abcdefABCDEF"


def _hex(raw, i, n):
    """The n hex digits at raw[i:], as a number, or None."""
    s = raw[i:i + n]
    return int(s, 16) if len(s) == n and all(c in HEX for c in s) else None


def unquote(raw):
    """Unquote a QDebug-quoted body (its opening quote already gone).

    Returns (lines, closed, end): the chunk's lines as [(bytes, raw end offset)], whether the
    closing quote was reached, and the offset just past it (len(raw) when it was not). A
    truncated escape at the end leaves the body open."""
    out, lines, i, n = bytearray(), [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c == 0x5C:                                   # a backslash
            if i + 1 >= n:
                break                                   # its escape goes on in the next piece
            e = raw[i + 1]
            if e == ord("n"):
                lines.append((bytes(out), i + 2)); out = bytearray(); i += 2
            elif e in SIMPLE:
                out += SIMPLE[e]; i += 2
            elif e == ord("x"):
                v = _hex(raw, i + 2, 2)
                if v is not None:
                    out.append(v); i += 4
                elif n - (i + 2) < 2:
                    break
                else:
                    out += b"\\x"; i += 2
            elif e in (ord("u"), ord("U")):
                w = 4 if e == ord("u") else 8
                v = _hex(raw, i + 2, w)
                if v is None:
                    if n - (i + 2) < w:
                        break
                    out += raw[i:i + 2]; i += 2
                    continue
                i += 2 + w
                if 0xD800 <= v < 0xDC00 and raw[i:i + 2] == b"\\u":   # a surrogate pair
                    lo = _hex(raw, i + 2, 4)
                    if lo is not None and 0xDC00 <= lo < 0xE000:
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00); i += 6
                out += chr(v).encode("utf-8", "replace") if v < 0x110000 else "\ufffd".encode()
            else:
                out += raw[i:i + 2]; i += 2             # not one of QDebug's: kept as it is
        elif c == 0x22:                                 # a quote
            if raw[i + 1:i + 2] == b'"':
                i += 2                                  # "" between \xHH and a hex digit
                continue
            lines.append((bytes(out), i + 1))
            return lines, True, i + 1
        else:
            out.append(c); i += 1
    lines.append((bytes(out), n))
    return lines, False, n


def main():
    try:
        with open(sys.argv[1], "rb") as f:
            log = f.read().split(b"\n")
    except (OSError, IndexError):
        return 0
    if log and log[-1] == b"":
        log.pop()
    out = sys.stdout.buffer

    def emit(b):
        out.write(b.decode("utf-8", "replace").encode("utf-8") + b"\n")

    carry = {}              # a plugin's line that its last chunk ended inside (2)
    name, body, held = None, None, []   # an open chunk: its plugin, raw body, cut lines (3)

    def finish(rest=b""):
        """The open chunk is whole (or all there is): print it."""
        lines = unquote(body)[0]
        if name in carry:
            lines[0] = (carry.pop(name) + lines[0][0], lines[0][1])
        last = len(lines) - 1
        for k, (text, end) in enumerate(lines):
            while held and held[0][0] < end:
                emit(held.pop(0)[1])
            if k == last and text and len(text) % PIECE == 0:
                while held:
                    emit(held.pop(0)[1])
                carry[name] = text                      # it goes on in this plugin's next chunk
            else:
                emit(text)
        while held:
            emit(held.pop(0)[1])
        if rest:
            emit(rest)                                  # another line, after the closing quote

    for line in log:
        start = 0
        if body is not None:
            if PREFIX.match(line) or STAMP.match(line):
                finish()                                # its rest never came: what there is
                body = None
            else:
                start, body = len(body), body + line    # the rest of the open chunk
        if body is None:
            m = PREFIX.match(line)
            if not m:
                emit(line)
                continue
            name, body, held = m.group(1), line[m.end():], []
        lines, closed, end = unquote(body)
        # Another process's line inside the chunk runs from its timestamp to the end of the
        # line, and its quotes are raw: the chunk is open there unless it closed before it.
        m = STAMP.search(body, start)
        if m and (not closed or end > m.start()):
            held.append((m.start(), body[m.start():]))
            body = body[:m.start()]
            continue
        if closed:
            rest, body = body[end:], body[:end]
            finish(rest)
            body = None
        # else: open, with nothing to cut; the next line is its rest if it has no prefix
    if body is not None:
        finish()
    for text in carry.values():
        emit(text)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:                             # a reader that stopped early
        sys.exit(0)
