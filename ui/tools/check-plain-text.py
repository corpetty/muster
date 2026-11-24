#!/usr/bin/env python3
"""Every text element in ui/src/qml renders as plain text (exo-3b3.18, audit P4-04).

Peers choose much of what Muster shows: chat bodies, invite notes, memos, statements, file
names, contact aliases. A Qt Quick Text with no textFormat is Text.AutoText, which renders a
string that looks like markup as StyledText: a peer could draw a fake status line in another
colour or size, or an <img> the engine may fetch. Muster's own copy uses no markup, so every
LogosText, Text and TextEdit declares textFormat: Text.PlainText (TextEdit.PlainText) in its
own block, rather than each peer-sourced use being found by hand.

  python3 ui/tools/check-plain-text.py          # FAIL lines name each element that does not
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
QML = ROOT / "ui" / "src" / "qml"
OPEN = re.compile(r"(?<![A-Za-z0-9_.])(LogosText|Text|TextEdit)\s*\{")


def block_of(src: str, start: int) -> str:
    """The text of the `{ … }` block opening at src[start] (nested blocks included)."""
    depth, i = 0, start
    in_str = None
    while i < len(src):
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in "\"'`":
            in_str = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
        i += 1
    return src[start:]


def own_props(block: str) -> str:
    """The block's own lines: nested child blocks removed, so a child's textFormat does not
    count for its parent."""
    inner = block[1:-1]
    out, depth = [], 0
    for c in inner:
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        elif depth == 0:
            out.append(c)
    return "".join(out)


def main() -> int:
    fails = []
    count = 0
    for f in sorted(QML.glob("*.qml")):
        src = f.read_text()
        for m in OPEN.finditer(src):
            # skip mentions inside comments
            line_start = src.rfind("\n", 0, m.start()) + 1
            if "//" in src[line_start : m.start()]:
                continue
            count += 1
            kind = m.group(1)
            props = own_props(block_of(src, m.end() - 1))
            want = "TextEdit.PlainText" if kind == "TextEdit" else "Text.PlainText"
            if not re.search(r"\btextFormat\s*:\s*" + re.escape(want), props):
                line = src.count("\n", 0, m.start()) + 1
                fails.append(f"FAIL  {f.relative_to(ROOT)}:{line}: {kind} without textFormat: {want}")
    for x in fails:
        print(x)
    if fails:
        print(f"{len(fails)} of {count} text elements may render a peer's markup")
        return 1
    print(f"plain text OK: {count} text elements in ui/src/qml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
