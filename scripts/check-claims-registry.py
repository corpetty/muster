#!/usr/bin/env python3
"""Validate the ADR-012 claims registry — the honesty scaffold of the walkthrough.

The educational layer's whole argument is that every "Logos protects X" claim is
backed by running code, and every gap is named with the fix that would close it.
The failure mode this guards is the one the vision doc calls out by name: a
caveat quietly disappears, a protection claim outlives the test that proved it,
and nothing breaks — honest documentation rots silently into a pitch. So the
claims are structured data, and CI checks what a human reviewer would not notice
was missing.

Modelled on `docs/diagrams/tools/check-manifest.py` and `check-readme-rot.py`,
same ADR-012 split: resolution FAILs, curriculum-completeness WARNs. CI cannot
check that a claim is *true* — that stays the author's obligation under the
honesty rules in docs/00-vision.md. It can check that the evidence resolves.

  FAIL  a `protects` claim's requirement id is not a real FURPS id
  FAIL  a `protects` claim's test does not resolve (file gone, or anchor absent)
  FAIL  an `others-leak` claim does not name both a system and an observer
  FAIL  a `gap` claim has no fix, or a status outside the closed set
  FAIL  a `gap` with status=specified does not carry the spec's lifecycle stage
  FAIL  a claim references a step that the registry does not define
  FAIL  a lifecycle step carries no claims at all
  WARN  a step is missing a `protects` or a `gap` claim (the two the four
        questions make mandatory — what is protected here, what is still open)
  WARN  a step has no `others-leak` claim (fine when nothing new leaks there)

The mandatory-per-step split is the four questions (docs/00-vision.md): every
step must say what it protects (with a test) and what is still open (with a fix);
"where others leak" is per-step where a fresh leak exists, so its absence warns
rather than fails.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
REGISTRY = REPO_ROOT / "contracts" / "claims" / "registry.json"
FURPS = REPO_ROOT / "docs" / "01-furps.md"

KINDS = {"protects", "others-leak", "gap"}
STATUSES = {"shipped", "specified", "partial", "none"}

# FURPS namespaces, longest-prefix first so "FS" wins over "F".
REQ_ID_RE = re.compile(r"\b(?:FS|F|U|R|P|S)-\d+\b")


def furps_ids() -> set[str]:
    """The set of requirement ids that actually exist, read from the source."""
    if not FURPS.exists():
        sys.exit(f"FAIL  no FURPS at {FURPS.relative_to(REPO_ROOT)}")
    return set(REQ_ID_RE.findall(FURPS.read_text(encoding="utf-8")))


def resolves(test: str) -> str | None:
    """None if the test reference resolves, else the reason it does not.

    A reference is `path` or `path::anchor`. The path must exist; if an anchor is
    given, it must appear in the file — so renaming the test it names, not just
    deleting the file, breaks the claim.
    """
    path, _, anchor = test.partition("::")
    target = REPO_ROOT / path
    if not target.exists():
        return f"file {path!r} does not exist"
    if anchor and anchor not in target.read_text(encoding="utf-8", errors="replace"):
        return f"anchor {anchor!r} not found in {path!r}"
    return None


def check(registry: dict, ids: set[str]) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []

    steps = registry.get("steps", [])
    step_ids = [s.get("id") for s in steps]
    seen: set[str] = set()
    for sid in step_ids:
        if not sid:
            failures.append("a step has no id")
        elif sid in seen:
            failures.append(f"step id {sid!r} is defined more than once")
        seen.add(sid)

    by_step: dict[str, list[dict]] = {sid: [] for sid in step_ids}

    for i, claim in enumerate(registry.get("claims", [])):
        where = f"claim[{i}] ({claim.get('title', '<untitled>')!r})"
        step = claim.get("step")
        if step not in by_step:
            failures.append(f"{where}: step {step!r} is not a defined lifecycle step")
        else:
            by_step[step].append(claim)

        kind = claim.get("kind")
        if kind not in KINDS:
            failures.append(f"{where}: kind={kind!r} is not one of {sorted(KINDS)}")
        if not claim.get("title") or not claim.get("body"):
            failures.append(f"{where}: every claim needs a title and a body")

        if kind == "protects":
            req = claim.get("requirement")
            if req not in ids:
                failures.append(
                    f"{where}: requirement={req!r} is not a FURPS id — a protection "
                    f"claim must resolve to a requirement that exists"
                )
            test = claim.get("test")
            if not test:
                failures.append(f"{where}: a protection claim must name a test")
            else:
                reason = resolves(test)
                if reason:
                    failures.append(f"{where}: test does not resolve — {reason}")

        elif kind == "others-leak":
            if not claim.get("system") or not claim.get("observer"):
                failures.append(
                    f"{where}: an others-leak claim must name both the system and "
                    f"the observer (no strawmen — docs/00-vision.md honesty rules)"
                )

        elif kind == "gap":
            if not claim.get("fix"):
                failures.append(f"{where}: a gap must point at a fix that would close it")
            status = claim.get("status")
            if status not in STATUSES:
                failures.append(
                    f"{where}: status={status!r} is not one of {sorted(STATUSES)} "
                    f"('coming soon' is not a status — docs/00-vision.md)"
                )
            if status == "specified" and not claim.get("spec_stage"):
                failures.append(
                    f"{where}: a 'specified' gap must carry the spec's lifecycle "
                    f"stage (a raw LIP is not a draft)"
                )

    for sid in step_ids:
        claims = by_step.get(sid, [])
        kinds = {c.get("kind") for c in claims}
        if not claims:
            failures.append(f"step {sid!r}: carries no claims — the walkthrough has a hole here")
            continue
        if "protects" not in kinds:
            warnings.append(f"step {sid!r}: no 'protects' claim — what does Logos protect here?")
        if "gap" not in kinds:
            warnings.append(f"step {sid!r}: no 'gap' claim — what is still open here, and what closes it?")
        if "others-leak" not in kinds:
            warnings.append(f"step {sid!r}: no 'others-leak' claim (fine if nothing new leaks here)")

    return failures, warnings


def main() -> int:
    argparse.ArgumentParser(description=__doc__).parse_args()

    if not REGISTRY.exists():
        print(f"FAIL  no claims registry at {REGISTRY.relative_to(REPO_ROOT)}")
        return 1
    try:
        registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"FAIL  {REGISTRY.relative_to(REPO_ROOT)} is not valid JSON — {exc}")
        return 1

    failures, warnings = check(registry, furps_ids())

    for w in warnings:
        print(f"WARN  {w}")
    for f in failures:
        print(f"FAIL  {f}")

    n_claims = len(registry.get("claims", []))
    n_steps = len(registry.get("steps", []))
    if failures:
        print(f"\n{len(failures)} failure(s) across {n_claims} claims, {n_steps} steps.")
        return 1
    if warnings:
        print(f"\n{len(warnings)} warning(s), no failures ({n_claims} claims, {n_steps} steps).")
    else:
        print(f"claims registry OK — {n_claims} claims across {n_steps} steps, all evidence resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
