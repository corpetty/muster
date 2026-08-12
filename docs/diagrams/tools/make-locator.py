#!/usr/bin/env python3
"""Emit one 'you are here' strip per pipeline stage.

Seven near-identical SVGs, so they are generated rather than hand-copied: a
change to the stage list or the palette has to land in one place or the series
stops agreeing with itself. Each strip is 880x82, drops in at the top of a post,
and lights the stage that instalment is about.

    python3 tools/make-locator.py

Output: series-locator-<stage>.svg, listed under the generator's `generates`
array in manifest.json. Edit this script, never the strips.
"""

from pathlib import Path

DIAGRAMS = Path(__file__).resolve().parent.parent

# Verbatim from the published seven-stage taxonomy; see manifest.json for the
# source. Order is load-bearing — the strip is a position indicator.
STAGES = [
    "Discovery",
    "Diligence",
    "Negotiation",
    "Contracting",
    "Ordering",
    "Settlement",
    "Enforcement",
]

PAPER, SURFACE, INK, MUTED, RULE = "#E4E6E0", "#F7F8F5", "#1A1F1C", "#656E66", "#C6CBC3"
SIGNAL, SIGNAL_SOFT = "#4B33C4", "#EAE6FA"

SANS = "'Instrument Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif"
MONO = "'DM Mono',ui-monospace,Menlo,monospace"

W, H = 880, 82
X0, SEG_W, GAP = 40, 109, 6
BAND_Y, BAND_H = 30, 40


def strip(active: int) -> str:
    name = STAGES[active]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
        f'width="{W}" height="{H}" font-family="{SANS}">',
        f"  <title>Pipeline locator — {name}</title>",
        f"  <desc>The seven-stage transaction pipeline with stage "
        f"{active + 1}, {name}, highlighted.</desc>",
        f'  <rect width="{W}" height="{H}" fill="{PAPER}"/>',
        f'  <text x="{X0}" y="18" font-size="8.5" font-family="{MONO}" '
        f'font-weight="600" letter-spacing="0.12em" fill="{MUTED}">'
        f"WHERE THIS POST SITS IN THE PIPELINE</text>",
    ]

    for i, stage in enumerate(STAGES):
        x = X0 + i * (SEG_W + GAP)
        on = i == active
        fill = SIGNAL_SOFT if on else SURFACE
        stroke = SIGNAL if on else RULE
        width = "1.4" if on else "1"
        num_fill = SIGNAL if on else MUTED
        txt_fill = SIGNAL if on else MUTED
        weight = "600" if on else "400"
        cx = x + SEG_W / 2
        parts += [
            f'  <rect x="{x}" y="{BAND_Y}" width="{SEG_W}" height="{BAND_H}" '
            f'rx="4" fill="{fill}" stroke="{stroke}" stroke-width="{width}"/>',
            f'  <text x="{cx:g}" y="45" font-size="8" font-family="{MONO}" '
            f'text-anchor="middle" fill="{num_fill}">{i + 1:02d}</text>',
            f'  <text x="{cx:g}" y="60" font-size="10.5" text-anchor="middle" '
            f'font-weight="{weight}" fill="{txt_fill}">{stage}</text>',
        ]

    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main() -> None:
    for i, stage in enumerate(STAGES):
        name = f"series-locator-{stage.lower()}.svg"
        (DIAGRAMS / name).write_text(strip(i), encoding="utf-8")
        print(f"  {name}")
    print(f"\n{len(STAGES)} strips. Generated — edit this script, never a strip.")


if __name__ == "__main__":
    main()
