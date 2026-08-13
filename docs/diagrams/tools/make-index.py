#!/usr/bin/env python3
"""Generate index.html — the landing page for the Pages site.

Built from manifest.json rather than written by hand, for the same reason the
provenance blocks are: a figure and its description maintained in two places
drift, and the whole programme exists to make that impossible.

A consequence worth keeping: a figure with no manifest entry does not appear
on the site. The pre-commit hook already refuses to let one exist; this makes
the omission visible rather than merely blocked.

    python3 tools/make-index.py
"""

from __future__ import annotations

import html
import json
import re
from pathlib import Path

DIAGRAMS = Path(__file__).resolve().parent.parent
MANIFEST = DIAGRAMS / "manifest.json"
OUT = DIAGRAMS / "index.html"

REPO = "https://github.com/corpetty/muster"

FAMILIES = [
    ("arch", "Deployment and packaging",
     "How the thing is put together, and what actually pins it."),
    ("pipeline", "The pipeline, and what leaks",
     "Seven stages, the infrastructure that runs each, and who is positioned to see what."),
    ("mech", "Muster's own guarantees",
     "Mostly specified and not yet built. Every figure says so on its face, above the content."),
    ("series", "Series chrome",
     "The per-post locator strip: seven stages, one lit."),
]

GRADE_LABEL = {
    "measured": "measured",
    "from-source": "from source",
    "illustrative": "illustrative",
}


def title_of(name: str) -> str:
    """The figure's own <title>, so the index cannot rename it."""
    path = DIAGRAMS / name
    if not path.exists():
        return name
    m = re.search(r"<title[^>]*>(.*?)</title>", path.read_text(encoding="utf-8"), re.S)
    return html.escape(m.group(1).strip()) if m else name


def esc(s: str) -> str:
    return html.escape(s or "")


def grades(fig: dict) -> str:
    seen = []
    for e in fig.get("evidence", []):
        g = e.get("grade")
        if g and g not in seen:
            seen.append(g)
    return "".join(
        f'<span class="g g-{g}">{GRADE_LABEL.get(g, g)}</span>' for g in seen
    )


def card(fig: dict) -> str:
    name = fig["file"]
    stem = name.rsplit(".", 1)[0]
    png = f"{stem}.png"
    thumb = (
        f'<a class="thumb" href="{esc(name)}"><img src="{esc(png)}" alt="" loading="lazy"></a>'
        if (DIAGRAMS / png).exists()
        else ""
    )
    return f"""      <li class="card">
        {thumb}
        <div class="meta">
          <h3><a href="{esc(name)}">{title_of(name)}</a></h3>
          <p>{esc(fig.get("shows", ""))}</p>
          <p class="tags"><span class="s s-{esc(fig.get("serves", "")).lower()}">{esc(fig.get("serves", ""))}</span>{grades(fig)}
            <a class="src" href="{REPO}/blob/main/docs/diagrams/{esc(name)}">source</a></p>
        </div>
      </li>"""


def substrate_card(fig: dict) -> str:
    name = fig["file"]
    n = len(fig.get("generates", []))
    return f"""      <li class="card card-live">
        <div class="meta">
          <h3><a href="{esc(name)}">{title_of(name)}</a> <span class="live">interactive</span></h3>
          <p>{esc(fig.get("shows", ""))}</p>
          <p class="tags"><span class="s s-{esc(fig.get("serves", "")).lower()}">{esc(fig.get("serves", ""))}</span>
            <span class="g g-frames">{n} exported frames</span>{grades(fig)}
            <a class="src" href="{REPO}/blob/main/docs/diagrams/{esc(name)}">source</a></p>
        </div>
      </li>"""


def main() -> None:
    figures = json.loads(MANIFEST.read_text(encoding="utf-8"))["figures"]

    substrates = [f for f in figures if f["file"].endswith(".html")]
    generators = [f for f in figures if f["file"].endswith(".py")]
    statics = [f for f in figures if f["file"].endswith(".svg")]

    sections = [
        '  <section>\n    <h2>Interactive</h2>\n'
        '    <p class="lede">One labelled substrate, a list of named traversals over it. '
        'Pick a view; everything else dims. Each view is also exported as a static frame for embedding.</p>\n'
        '    <ul class="cards">\n'
        + "\n".join(substrate_card(f) for f in substrates)
        + "\n    </ul>\n  </section>"
    ]

    for prefix, heading, lede in FAMILIES:
        group = [f for f in statics if f["file"].startswith(prefix + "-")]
        gen = [g for g in generators if any(
            x.startswith(prefix + "-") for x in g.get("generates", []))]
        if not group and not gen:
            continue
        body = "\n".join(card(f) for f in group)
        if gen:
            for g in gen:
                strips = g.get("generates", [])
                links = " · ".join(
                    f'<a href="{esc(s)}">{esc(s.rsplit("-", 1)[-1].replace(".svg", ""))}</a>'
                    for s in strips
                )
                body += f"""
      <li class="card card-strip">
        <div class="meta">
          <h3>{esc(g.get("shows", ""))}</h3>
          <p class="tags">{links}</p>
          <p class="tags"><a class="src" href="{REPO}/blob/main/docs/diagrams/{esc(g["file"])}">generator</a></p>
        </div>
      </li>"""
        sections.append(
            f'  <section>\n    <h2>{esc(heading)}</h2>\n'
            f'    <p class="lede">{esc(lede)}</p>\n'
            f'    <ul class="cards">\n{body}\n    </ul>\n  </section>'
        )

    OUT.write_text(PAGE.format(sections="\n\n".join(sections)), encoding="utf-8")
    print(f"  index.html — {len(substrates)} substrates, {len(statics)} figures")


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Muster — diagrams</title>
<!-- Generated by tools/make-index.py from manifest.json. Do not edit. -->
<style>
  :root {{
    --paper:#E4E6E0; --surface:#F7F8F5; --ink:#1A1F1C; --muted:#656E66; --rule:#C6CBC3;
    --signal:#4B33C4; --signal-soft:#EAE6FA;
    --settled:#1E6B52; --settled-soft:#DFEDE6;
    --alarm:#A32D1E; --alarm-soft:#F6E3DF;
    --outside:#23282A; --outside-ink:#DCE2DE;
    --sans:'Instrument Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
    --mono:'DM Mono',ui-monospace,'SF Mono',Menlo,monospace;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font-family: var(--sans); background: var(--paper); color: var(--ink);
    margin: 0 auto; padding: 3rem 1.5rem 5rem; max-width: 1080px; line-height: 1.65;
  }}
  h1 {{ font-size: 2rem; letter-spacing: -0.5px; margin: 0 0 .3rem; }}
  .sub {{ color: var(--muted); font-size: 1.05rem; margin: 0 0 1.6rem; max-width: 62ch; }}
  h2 {{ font-size: 1.15rem; margin: 0 0 .25rem; }}
  .lede {{ color: var(--muted); font-size: .92rem; margin: 0 0 1rem; max-width: 70ch; }}
  section {{ margin: 2.6rem 0 0; }}
  .cards {{ list-style: none; padding: 0; margin: 0; display: grid; gap: 1rem;
            grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); }}
  .card {{ background: var(--surface); border: 1px solid var(--rule); border-radius: 10px;
           overflow: hidden; display: flex; flex-direction: column; }}
  .card-live {{ border-color: var(--signal); background: var(--signal-soft); }}
  .card-strip {{ grid-column: 1 / -1; }}
  .thumb {{ display: block; background: var(--paper); border-bottom: 1px solid var(--rule); }}
  .thumb img {{ display: block; width: 100%; height: auto; }}
  .meta {{ padding: .85rem 1rem 1rem; }}
  .meta h3 {{ font-size: .98rem; margin: 0 0 .35rem; }}
  .meta p {{ font-size: .86rem; color: #3F4742; margin: 0 0 .5rem; }}
  a {{ color: var(--signal); }}
  a:hover {{ text-decoration-thickness: 2px; }}
  .live {{ font-family: var(--mono); font-size: .62rem; text-transform: uppercase;
           letter-spacing: .08em; background: var(--signal); color: var(--surface);
           padding: .12em .5em; border-radius: 3px; vertical-align: 2px; }}
  .tags {{ display: flex; flex-wrap: wrap; gap: .4rem; align-items: center; }}
  .s, .g {{ font-family: var(--mono); font-size: .62rem; text-transform: uppercase;
            letter-spacing: .06em; padding: .16em .5em; border-radius: 3px; border: 1px solid; }}
  .s-both {{ color: var(--signal); border-color: var(--signal); background: var(--signal-soft); }}
  .s-post {{ color: var(--muted); border-color: var(--rule); background: var(--paper); }}
  .s-build {{ color: var(--muted); border-color: var(--rule); background: var(--paper); }}
  .g-measured {{ color: var(--settled); border-color: var(--settled); background: var(--settled-soft); }}
  .g-from-source {{ color: var(--muted); border-color: var(--rule); background: var(--paper); }}
  .g-illustrative {{ color: var(--alarm); border-color: var(--alarm); background: var(--alarm-soft); }}
  .g-frames {{ color: var(--muted); border-color: var(--rule); background: var(--paper); }}
  .src {{ font-family: var(--mono); font-size: .68rem; margin-left: auto; }}
  .note {{ background: var(--outside); color: var(--outside-ink); border-radius: 10px;
           padding: 1.1rem 1.3rem; margin: 3rem 0 0; font-size: .9rem; }}
  .note h2 {{ color: var(--outside-ink); font-size: 1rem; }}
  .note p {{ margin: .5rem 0 0; color: #96A19B; }}
  .note strong {{ color: var(--outside-ink); }}
  footer {{ margin: 2rem 0 0; font-size: .82rem; color: var(--muted); }}
  @media (prefers-color-scheme: dark) {{
    body {{ background: #1A1F1C; color: #E4E6E0; }}
    .card {{ background: #23282A; border-color: #3A4144; }}
    .meta p {{ color: #B6BEB8; }}
    h1, h2, .meta h3 a {{ color: #E4E6E0; }}
    a {{ color: #8FA3F5; }}
    .card-live {{ background: #262340; border-color: #8FA3F5; }}
    .thumb {{ background: #E4E6E0; }}
  }}
</style>
</head>
<body>

<h1>Muster — diagrams</h1>
<p class="sub">Architecture and pipeline figures for <a href="{repo}">Muster</a>, a local-first client for coordinating
multi-party transactions inside conversations. Every figure declares where its facts came from, and which of its
content is measured, read from source, or illustrative.</p>

{sections}

<div class="note">
  <h2>What the marks mean</h2>
  <p><strong>measured</strong> — observed on a specific machine, with a date. <strong>from source</strong> — read off
  code or a contract, not separately exercised. <strong>illustrative</strong> — characterises a situation; not a
  measurement of any named system, and never to be read as one.</p>
  <p>Several figures describe guarantees that are <strong>specified and not yet built</strong>. Each says so in a strip
  above its content, with the requirement ids, the phase that builds it, and what exists today instead — so a
  screenshot cannot lose the caveat.</p>
</div>

<footer>
  Generated from <a href="{repo}/blob/main/docs/diagrams/manifest.json">manifest.json</a> ·
  <a href="{repo}/blob/main/docs/diagrams/README.md">the catalogue and its conventions</a> ·
  the engine is forked from <a href="https://github.com/logos-co/assembly">logos-co/assembly</a>'s basecamp stack preview
</footer>

</body>
</html>
""".replace("{repo}", REPO)


if __name__ == "__main__":
    main()
