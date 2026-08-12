#!/usr/bin/env python3
"""Validate docs/diagrams/manifest.json against the tree.

The failure mode this exists for is not a wrong diagram — it is a diagram that
keeps rendering, keeps looking authoritative, and quietly describes a topology
that changed two phases ago. Nothing breaks when that happens, which is exactly
why it needs a machine watching.

Modelled on ADR-012's split: some things must *resolve*, others must merely be
*declared* from a closed vocabulary. CI cannot check that a figure is true.

  FAIL  a figure file listed in the manifest does not exist
  FAIL  a figure in docs/diagrams/ is not listed in the manifest
  FAIL  a source path a figure derives from does not exist
  FAIL  `serves` or an evidence `grade` is outside its closed vocabulary
  FAIL  a figure has no evidence entries at all
  WARN  a source's content hash differs from the one recorded at render time

The warning is a prompt to look, not a verdict: most source changes do not
invalidate a figure. Re-stamp with --update once you have looked.

Generated frames (§3.2) are exports, not authored artefacts, so they inherit
their provenance from the substrate that produced them and are exempt from the
unlisted-figure check.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DIAGRAMS = REPO_ROOT / "docs" / "diagrams"
MANIFEST = DIAGRAMS / "manifest.json"

SERVES = {"BUILD", "POST", "BOTH"}
GRADES = {"measured", "from-source", "illustrative"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


PROVENANCE_RE = re.compile(r"[ \t]*<!-- provenance\b.*?-->\n?", re.DOTALL)

# Rough advance width as a fraction of font-size. These figures use one sans and
# one mono and never justify, so a single factor per family gets close enough to
# catch a line that is 20% too long — which is the failure that actually happens.
# It cannot catch a line that is 2% too long, and does not try.
_SANS, _MONO, _BOLD = 0.52, 0.60, 1.06
_OVERFLOW_SLACK = 1.02  # only complain past 2% over, to keep this quiet


def _text_width(node, size: float, mono: bool, bold: bool) -> float:
    """Estimated advance width of a <text>, including its tspans."""
    chars = 0
    for n in node.childNodes:
        if n.nodeType == n.TEXT_NODE:
            chars += len(n.data)
        elif n.nodeType == n.ELEMENT_NODE and n.tagName == "tspan":
            chars += sum(
                len(c.data) for c in n.childNodes if c.nodeType == c.TEXT_NODE
            )
    factor = _MONO if mono else _SANS
    if bold:
        factor *= _BOLD
    return chars * size * factor


def check_text_fit(path: Path) -> list[str]:
    """Flag <text> that probably runs off the canvas.

    A clipped label still renders and still looks fine in the source — it is only
    visible in the raster, which is exactly the kind of thing that ships.
    """
    import xml.dom.minidom as minidom

    try:
        doc = minidom.parse(str(path))
    except Exception as exc:  # a malformed SVG is a louder problem than layout
        return [f"{path.name}: does not parse as XML — {exc}"]

    root = doc.documentElement
    vb = (root.getAttribute("viewBox") or "").split()
    if len(vb) != 4:
        return []
    canvas = float(vb[2])

    out = []
    for node in doc.getElementsByTagName("text"):
        try:
            x = float(node.getAttribute("x") or 0)
        except ValueError:
            continue
        size_attr = node.getAttribute("font-size")
        try:
            size = float(size_attr) if size_attr else 12.0
        except ValueError:
            size = 12.0

        family = node.getAttribute("font-family") or ""
        mono = "Mono" in family or "mono" in family
        bold = (node.getAttribute("font-weight") or "") in ("600", "700", "bold")

        w = _text_width(node, size, mono, bold)
        anchor = node.getAttribute("text-anchor") or "start"
        right = x + w if anchor == "start" else (x + w / 2 if anchor == "middle" else x)

        if right > canvas * _OVERFLOW_SLACK:
            snippet = (node.firstChild.data if node.firstChild and
                       node.firstChild.nodeType == node.TEXT_NODE else "")[:40]
            out.append(
                f"{path.name}: text at x={x:g} likely overflows the {canvas:g}px "
                f"canvas (~{right:.0f}px) — {snippet!r}"
            )
    return out


def render_provenance(fig: dict) -> str:
    """The manifest entry, as the comment block that lives inside the SVG.

    Generated rather than hand-kept, so the block a reader finds in the figure
    and the row CI checks cannot drift apart. `--` is illegal inside an XML
    comment, so any that survive in prose become en dashes.
    """
    label_w = 10

    def field(label: str, lines: list[str]) -> list[str]:
        if not lines:
            return []
        head = f"     {(label + ':').ljust(label_w)}{lines[0]}"
        rest = [f"     {''.ljust(label_w)}{ln}" for ln in lines[1:]]
        return [head, *rest]

    def wrap(text: str, indent: str = "") -> list[str]:
        return textwrap.wrap(text, width=74 - len(indent)) or [""]

    body: list[str] = []
    body += field("serves", [fig.get("serves", "")])
    body += field("shows", wrap(fig.get("shows", "")))
    body += field("sources", [s["path"] for s in fig.get("sources", [])])

    ev: list[str] = []
    for item in fig.get("evidence", []):
        lines = wrap(f"[{item.get('grade')}] {item.get('note', '')}")
        ev += [lines[0]] + [f"    {ln}" for ln in lines[1:]]
    body += field("evidence", ev)

    if fig.get("recheck"):
        body += field("recheck", wrap(fig["recheck"]))

    # Sanitise the BODY only, then add the delimiters — so the comment markers
    # themselves can never be caught by the `--` substitution.
    inner = "\n".join(body).replace("--", "–")
    return f"<!-- provenance\n{inner}\n-->\n"


def stamp(manifest: dict) -> int:
    """Write each figure's provenance block in after its </desc>."""
    written = 0
    for fig in manifest.get("figures", []):
        path = DIAGRAMS / fig["file"]
        # Only SVGs, matching what check() validates. An interactive substrate is
        # an HTML page that happens to contain a <desc>; stamping it would write
        # a block nothing ever checks, duplicating the header comment that
        # already explains the file.
        if not path.exists() or path.suffix != ".svg":
            continue
        text = path.read_text(encoding="utf-8")
        block = render_provenance(fig)
        stripped = PROVENANCE_RE.sub("", text)
        if "</desc>" not in stripped:
            print(f"WARN  {fig['file']}: no <desc> to anchor the block to; skipped")
            continue
        updated = stripped.replace("</desc>\n", "</desc>\n" + block, 1)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            written += 1
    return written


def load() -> dict:
    if not MANIFEST.exists():
        sys.exit(f"FAIL  no manifest at {MANIFEST.relative_to(REPO_ROOT)}")
    return json.loads(MANIFEST.read_text())


def check(manifest: dict) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []

    listed: set[str] = set()

    for fig in manifest.get("figures", []):
        name = fig.get("file", "<unnamed>")
        listed.add(name)
        where = f"{name}:"

        if not (DIAGRAMS / name).exists():
            failures.append(f"{where} listed in the manifest but not in docs/diagrams/")

        if fig.get("serves") not in SERVES:
            failures.append(
                f"{where} serves={fig.get('serves')!r} is not one of {sorted(SERVES)}"
            )

        evidence = fig.get("evidence", [])
        if not evidence:
            failures.append(
                f"{where} no evidence entries — every figure declares which of its "
                f"content is measured, from source, or illustrative"
            )
        for item in evidence:
            if item.get("grade") not in GRADES:
                failures.append(
                    f"{where} evidence grade={item.get('grade')!r} is not one of "
                    f"{sorted(GRADES)}"
                )

        figpath = DIAGRAMS / name
        if figpath.exists() and figpath.suffix == ".svg":
            text = figpath.read_text(encoding="utf-8")
            found = PROVENANCE_RE.search(text)
            if not found:
                failures.append(f"{where} carries no provenance block — run --stamp")
            elif found.group(0).strip() != render_provenance(fig).strip():
                failures.append(
                    f"{where} provenance block has drifted from its manifest entry "
                    f"— run --stamp"
                )

        for src in fig.get("sources", []):
            path = REPO_ROOT / src["path"]
            if not path.exists():
                failures.append(
                    f"{where} derives from {src['path']}, which no longer exists"
                )
                continue
            recorded = src.get("sha256")
            actual = sha256(path)
            if recorded and recorded != actual:
                warnings.append(
                    f"{where} {src['path']} has changed since this figure was "
                    f"rendered — check whether the figure is still true, then "
                    f"re-stamp with --update"
                )

    generated = {
        g for fig in manifest.get("figures", []) for g in fig.get("generates", [])
    }
    for svg in sorted(DIAGRAMS.glob("*.svg")):
        if svg.name not in listed and svg.name not in generated:
            failures.append(
                f"{svg.name}: present in docs/diagrams/ but absent from the manifest"
            )
        # Layout, not provenance — but it is the same failure shape: renders
        # fine, looks fine in the source, wrong only in the raster.
        #
        # Hand-authored figures only. An exported frame gets its font-size and
        # text-anchor from the substrate's stylesheet, which this estimator
        # cannot read, so every centred label there reads as an overflow. The
        # substrate is checked by looking at it; these are checked by counting.
        if svg.name not in generated:
            warnings.extend(check_text_fit(svg))

    return failures, warnings


def update(manifest: dict) -> int:
    restamped = 0
    for fig in manifest.get("figures", []):
        for src in fig.get("sources", []):
            path = REPO_ROOT / src["path"]
            if not path.exists():
                continue
            actual = sha256(path)
            if src.get("sha256") != actual:
                src["sha256"] = actual
                restamped += 1
    # ensure_ascii=False: the notes are prose and carry section marks, em dashes
    # and arrows. Escaping them to \uXXXX makes the manifest unreviewable in a
    # diff, which defeats the point of it being the thing a human checks.
    MANIFEST.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return restamped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--update",
        action="store_true",
        help="re-stamp source hashes to their current values",
    )
    ap.add_argument(
        "--stamp",
        action="store_true",
        help="write each figure's provenance block in from its manifest entry",
    )
    args = ap.parse_args()

    manifest = load()

    if args.update:
        n = update(manifest)
        print(f"re-stamped {n} source hash{'es' if n != 1 else ''}")
        manifest = load()

    if args.stamp:
        n = stamp(manifest)
        print(f"stamped {n} figure{'s' if n != 1 else ''}")

    failures, warnings = check(manifest)

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
