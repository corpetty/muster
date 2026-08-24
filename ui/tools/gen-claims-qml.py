#!/usr/bin/env python3
"""Generate ui/src/qml/ClaimsRegistry.qml from the ADR-012 claims registry.

The registry (contracts/claims/registry.json) is the single source of truth and
is CI-validated by scripts/check-claims-registry.py — every protects claim
resolves to a requirement and a test, every gap to a fix and a status. This
turns that validated data into a QML value object the view can render, so the
walkthrough surface and the checked registry cannot drift into two truths.

Generated-and-committed, like the muster.lidl Nim surface and the diagrams'
provenance blocks: the .qml is committed (so the ui flake, which cannot read
sibling repo dirs, has it as a build input), and `--check` fails the build if it
has drifted from the registry. Editing the .qml by hand is not a way to change
it — regenerate from the registry.

Emitted as a plain QtObject component (not a pragma-Singleton), so it needs no
qmldir registration: the view instantiates `ClaimsRegistry { id: registry }`.
Deliberately data-only — no imports beyond QtQuick, no bindings, no layout — so
that it is the one QML file whose correctness is legible without a launch, the
gate ADR-011 otherwise (rightly) demands.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
REGISTRY = REPO_ROOT / "contracts" / "claims" / "registry.json"
OUT = REPO_ROOT / "ui" / "src" / "qml" / "ClaimsRegistry.qml"

# User-facing prose is wrapped in qsTr() for i18n (matching demo/muster-ui's
# VisibilityClaims.qml); identifiers and evidence pointers are plain strings.
TRANSLATED = {"title", "summary", "body", "fix"}
# Field emission order, so the generated file is stable across runs.
CLAIM_FIELDS = ["step", "kind", "title", "body", "requirement", "test",
                "system", "observer", "fix", "status", "spec_stage"]

HEADER = """\
// GENERATED — do not edit. Source: contracts/claims/registry.json
// Regenerate: ui/tools/gen-claims-qml.py  ·  CI fails if this drifts (--check).
//
// The ADR-012 claims registry as a QML value object: the walkthrough's four
// questions as data, not prose in a delegate. `kind` is closed
// (protects | others-leak | gap); a gap's `status` is closed
// (shipped | specified | partial | none). Every field here was resolved against
// a real requirement and a real test by scripts/check-claims-registry.py before
// it reached this file — an empty field would have failed that gate, where prose
// in a view would have read fine and been wrong.

import QtQuick

QtObject {
    id: root
"""

FOOTER = """\

    function forStep(stepId) {
        return root.claims.filter(function (c) { return c.step === stepId; });
    }

    function titleOf(stepId) {
        for (var i = 0; i < root.steps.length; ++i)
            if (root.steps[i].id === stepId)
                return root.steps[i].title;
        return stepId;
    }
}
"""


def q(value: str) -> str:
    """A QML double-quoted string literal (escape backslash, quote, newline)."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def field(key: str, value: str) -> str:
    lit = f"qsTr({q(value)})" if key in TRANSLATED else q(value)
    return f"{key}: {lit}"


def render(registry: dict) -> str:
    lines = [HEADER]

    lines.append("    readonly property var steps: [")
    for s in registry.get("steps", []):
        parts = ", ".join(field(k, s[k]) for k in ("id", "title", "summary") if k in s)
        lines.append(f"        {{ {parts} }},")
    lines.append("    ]")
    lines.append("")

    lines.append("    readonly property var claims: [")
    for c in registry.get("claims", []):
        parts = ", ".join(field(k, c[k]) for k in CLAIM_FIELDS if k in c)
        lines.append(f"        {{ {parts} }},")
    lines.append("    ]")

    lines.append(FOOTER)
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="fail if the committed .qml differs from the registry")
    args = ap.parse_args()

    if not REGISTRY.exists():
        print(f"FAIL  no registry at {REGISTRY.relative_to(REPO_ROOT)}")
        return 1
    generated = render(json.loads(REGISTRY.read_text(encoding="utf-8")))

    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != generated:
            print(
                f"FAIL  {OUT.relative_to(REPO_ROOT)} has drifted from "
                f"{REGISTRY.relative_to(REPO_ROOT)} — run ui/tools/gen-claims-qml.py"
            )
            return 1
        print(f"{OUT.relative_to(REPO_ROOT)} is in sync with the registry.")
        return 0

    OUT.write_text(generated, encoding="utf-8")
    print(f"wrote {OUT.relative_to(REPO_ROOT)} "
          f"({len(generated.splitlines())} lines from "
          f"{len(json.loads(REGISTRY.read_text())['claims'])} claims)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
