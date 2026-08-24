#!/usr/bin/env python3
"""Keep the entry-point READMEs from silently falling behind the build.

The failure mode this exists for is the one that already happened: the root
README kept rendering, kept looking authoritative, and described a repo where
`module/` did not exist and P0 had not started — four days and four phases after
that stopped being true. Nothing broke, nobody was warned, because the READMEs
are in nobody's update loop. The plan docs (`CLAUDE.md`, the implementation
plan, FURPS) churn constantly; the READMEs — the first thing a newcomer reads —
do not, and no machine was watching the gap.

Modelled on `docs/diagrams/tools/check-manifest.py` and the same ADR-012 split:
some things must *resolve*, others can only be *declared* and watched for drift.
CI cannot check that a README is true — but it can check two proxies for rot.

  FAIL  a repo-relative link in a watched README points at a path that is gone
  FAIL  a watched README carries no rot-check marker (run --stamp)
  WARN  `CLAUDE.md`'s "Current phase" section has changed since a README was
        last reconciled against it — read the README, then re-stamp

The warning is a prompt to look, not a verdict: most edits to the phase section
(a typo, one more landed bullet) do not falsify a README's Status. But the one
that does — a phase rolling over, a subsystem going from "planned" to "landed" —
looks identical to the machine, so it hands you the prompt and trusts you to
read. Do not silence a warning by re-stamping without reading the diff; that
converts the one signal here into noise, exactly as the diagram tool warns.

Re-stamp with --stamp once you have looked.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

# The source of truth for "what state is the build actually in". Its "Current
# phase" section is the narrative every entry-point README's Status must track.
PHASE_SOURCE = REPO_ROOT / "CLAUDE.md"
PHASE_HEADING = "## Current phase"

# The READMEs that make current-state claims and therefore rot. Deliberately not
# every README: demo/README.md documents a frozen speed build and docs/00-vision
# is normative — both are old on purpose, not drifted, so watching them would
# only manufacture warnings. Add a file here when it starts describing "now".
WATCHED = [
    "README.md",
    "module/README.md",
]

MARKER_RE = re.compile(r"<!-- rot-check:.*?sha256=([0-9a-f]{64}).*?-->", re.DOTALL)

# Markdown inline links `[text](target)` and reference definitions `[id]: target`.
# We check link *targets* only — high precision. Bare code spans like `logoscore
# -m <dir>` read like paths but are not, and checking them manufactures noise.
INLINE_LINK_RE = re.compile(r"\]\(\s*(<[^>]+>|[^)\s]+)")
REF_LINK_RE = re.compile(r"^\[[^\]]+\]:\s*(\S+)", re.MULTILINE)


def phase_fingerprint() -> str:
    """SHA-256 of CLAUDE.md's "Current phase" section, heading to next section."""
    if not PHASE_SOURCE.exists():
        sys.exit(f"FAIL  no phase source at {PHASE_SOURCE.relative_to(REPO_ROOT)}")
    text = PHASE_SOURCE.read_text(encoding="utf-8")
    start = text.find(PHASE_HEADING)
    if start == -1:
        sys.exit(
            f"FAIL  {PHASE_SOURCE.relative_to(REPO_ROOT)} has no {PHASE_HEADING!r} "
            f"section — this tool keys off it; update PHASE_HEADING if it moved"
        )
    rest = text[start + len(PHASE_HEADING):]
    nxt = re.search(r"^## ", rest, re.MULTILINE)
    section = rest[: nxt.start()] if nxt else rest
    return hashlib.sha256(section.strip().encode("utf-8")).hexdigest()


def link_targets(text: str) -> list[str]:
    targets = INLINE_LINK_RE.findall(text) + REF_LINK_RE.findall(text)
    return [t[1:-1] if t.startswith("<") and t.endswith(">") else t for t in targets]


def is_local_path(target: str) -> bool:
    if not target or target.startswith(("#", "http://", "https://", "mailto:")):
        return False
    return True


def check_links(readme: Path) -> list[str]:
    """FAIL on any repo-relative link target that does not resolve."""
    text = readme.read_text(encoding="utf-8")
    rel = readme.relative_to(REPO_ROOT)
    out = []
    for target in link_targets(text):
        if not is_local_path(target):
            continue
        # Strip a #fragment and a :line suffix before resolving to a file.
        path = target.split("#", 1)[0].split(" ", 1)[0]
        path = re.sub(r":\d+$", "", path)
        if not path:
            continue
        if not (readme.parent / path).exists():
            out.append(f"{rel}: link to {target!r} points at a path that does not exist")
    return out


def stamp(fingerprint: str) -> int:
    """Write the current phase fingerprint into each watched README's marker."""
    marker = f"<!-- rot-check: current-phase={PHASE_SOURCE.name} sha256={fingerprint} -->"
    written = 0
    for name in WATCHED:
        path = REPO_ROOT / name
        if not path.exists():
            print(f"WARN  {name}: watched but not present; skipped")
            continue
        text = path.read_text(encoding="utf-8")
        stripped = MARKER_RE.sub("", text).rstrip("\n")
        updated = f"{stripped}\n\n{marker}\n"
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            written += 1
    return written


def check(fingerprint: str) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []
    for name in WATCHED:
        path = REPO_ROOT / name
        if not path.exists():
            failures.append(f"{name}: watched by the rot-check but not present")
            continue
        failures.extend(check_links(path))
        found = MARKER_RE.search(path.read_text(encoding="utf-8"))
        if not found:
            failures.append(f"{name}: carries no rot-check marker — run --stamp")
        elif found.group(1) != fingerprint:
            warnings.append(
                f"{name}: CLAUDE.md's \"Current phase\" has changed since this "
                f"README was reconciled — read it, confirm the Status still holds, "
                f"then re-stamp with --stamp"
            )
    return failures, warnings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--stamp",
        action="store_true",
        help="re-record the current phase fingerprint into each watched README",
    )
    args = ap.parse_args()

    fingerprint = phase_fingerprint()

    if args.stamp:
        n = stamp(fingerprint)
        print(f"stamped {n} README{'s' if n != 1 else ''}")

    failures, warnings = check(fingerprint)

    for w in warnings:
        print(f"WARN  {w}")
    for f in failures:
        print(f"FAIL  {f}")

    if failures:
        print(f"\n{len(failures)} failure(s).")
        return 1
    if warnings:
        print(f"\n{len(warnings)} warning(s), no failures.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
