#!/usr/bin/env python3
"""Invariant tests are append-only (CLAUDE.md, working agreements): enforce it on a diff.

    scripts/check-invariant-tests-append-only.py <base-ref> [<head-ref>]   # head defaults to HEAD

Between the merge base of <base-ref> and <head-ref>, fails when:

  - a file under module/tests/probes/ or contracts/specs/ is deleted or renamed away, or
  - a probe file has fewer assertion lines (doAssert / assert / check / expect) than it had.

Moving a spec to contracts/specs/retired/ is a rename the policy allows only with a reason.
A deliberate weakening is allowed when a commit in the range carries the trailer

    Invariant-Test-Weakened: <why, and the ADR or issue that decided it>

so it is a decision someone wrote down, never an accident of a refactor.
"""
import re
import subprocess
import sys

GUARDED = ("module/tests/probes/", "contracts/specs/")
ASSERT = re.compile(r"^\s*(doAssert|assert|check|expect)\b")
TRAILER = re.compile(r"^Invariant-Test-Weakened:\s*\S", re.M)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def asserts_at(ref: str, path: str) -> int:
    try:
        text = git("show", f"{ref}:{path}")
    except subprocess.CalledProcessError:
        return 0
    return sum(1 for line in text.splitlines() if ASSERT.match(line))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    head = sys.argv[2] if len(sys.argv) > 2 else "HEAD"
    base = git("merge-base", sys.argv[1], head).strip()

    problems = []
    for line in git("diff", "--name-status", "-M", base, head, "--", *GUARDED).splitlines():
        parts = line.split("\t")
        status, path = parts[0], parts[1]
        if status.startswith("D"):
            problems.append(f"deleted: {path}")
        elif status.startswith("R"):
            problems.append(f"renamed: {path} -> {parts[2]}")
        elif status.startswith("M") and path.startswith("module/tests/probes/") and path.endswith(".nim"):
            before, after = asserts_at(base, path), asserts_at(head, path)
            if after < before:
                problems.append(f"fewer assertions: {path} ({before} -> {after})")

    if not problems:
        print("invariant tests: append-only OK")
        return 0
    if TRAILER.search(git("log", "--format=%B", f"{base}..{head}")):
        print("invariant tests weakened, with a recorded reason (Invariant-Test-Weakened):")
        for p in problems:
            print(f"  {p}")
        return 0
    print("invariant tests are append-only (CLAUDE.md); this range weakens them:")
    for p in problems:
        print(f"  {p}")
    print("If this is deliberate, add an 'Invariant-Test-Weakened: <reason>' trailer to a commit.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
