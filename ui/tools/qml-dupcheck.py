#!/usr/bin/env python3
"""Catch the QML error class `nix build` can't: "Property value set multiple times".

`nix build` does not evaluate QML (ADR-011), so a duplicate property or signal handler
on one object — e.g. a second `onComposingChanged:` where the file already binds one —
compiles fine and only explodes when the ui-host instantiates the view ("Type Room
unavailable … Property value set multiple times"). That cost a whole AppImage rebuild
once; this static check flags it before the build.

It is a heuristic, not a QML parser: it tracks object scopes (`Type { … }`) versus
JS/grouped-property blocks (opened by `: {`, `function`, `if (…) {`, …) and reports a
property/handler name bound twice within the SAME object scope. Run it over the QML you
touched; a clean run is not a proof of correctness, only the absence of this one class.

Usage:  python3 ui/tools/qml-dupcheck.py ui/src/qml/*.qml
Exit status: 1 if any duplicate is found, else 0.
"""
import re
import sys

PROP_RE = re.compile(r'^\s*((?:on[A-Z]\w+)|(?:[A-Za-z_]\w*(?:\.\w+)*))\s*:')
TYPE_OPEN_RE = re.compile(r'^\s*[A-Z][\w.]*\s*\{\s*$')


def check(path: str) -> list:
    lines = open(path).read().split('\n')
    stack = [dict()]      # per-scope: property name -> first line seen
    kinds = ['object']
    issues = []
    for ln, raw in enumerate(lines, 1):
        code = re.sub(r'//.*$', '', raw)   # naive line-comment strip (ignores // in strings)
        stripped = code.strip()
        if not stripped:
            continue
        if kinds[-1] == 'object':
            m = PROP_RE.match(code)
            if m and not stripped.endswith('{'):   # `x: {` is a scope open, handled below
                name = m.group(1)
                if name in stack[-1]:
                    issues.append((name, stack[-1][name], ln))
                else:
                    stack[-1][name] = ln
        opens = code.count('{')
        closes = code.count('}')
        for _ in range(opens):
            is_obj = bool(TYPE_OPEN_RE.match(code)) or bool(
                re.match(r'^\s*[A-Z][\w.]*\s*\{', code) and ':' not in code.split('{')[0])
            stack.append(dict())
            kinds.append('object' if is_obj else 'js')
        for _ in range(closes):
            if len(stack) > 1:
                stack.pop()
                kinds.pop()
    return issues


def main(argv) -> int:
    if len(argv) < 2:
        print("usage: qml-dupcheck.py FILE.qml [FILE.qml ...]", file=sys.stderr)
        return 2
    bad = False
    for path in argv[1:]:
        issues = check(path)
        if issues:
            bad = True
            print(f"[{path}] duplicate property/handler in one object (QML would refuse it):")
            for name, a, b in issues:
                print(f"   {name}: bound at line {a} and again at line {b}")
        else:
            print(f"[{path}] ok — no same-scope duplicate property/handler")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
