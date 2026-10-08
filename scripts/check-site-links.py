#!/usr/bin/env python3
"""Every relative link in the assembled Pages site resolves to a file in it.

The landing page links into diagrams/ and atlas/, and the diagram index links
back up; a figure renamed or a page moved would 404 on the live site with
nothing to warn anyone. This reads every .html in the assembled directory and
fails on any relative href or src that names no file there. Absolute URLs,
fragments, mailto: and data: are not checked.

    python3 scripts/check-site-links.py _site
"""

from __future__ import annotations

import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


class Links(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.found: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for name, value in attrs:
            if name in ("href", "src") and value:
                self.found.append(value)


def relative(link: str) -> str | None:
    parts = urlsplit(link)
    if parts.scheme or parts.netloc or link.startswith(("#", "//")):
        return None
    return unquote(parts.path) or None


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    site = Path(sys.argv[1]).resolve()
    broken: list[str] = []
    pages = sorted(site.rglob("*.html"))
    checked = 0
    for page in pages:
        parser = Links()
        parser.feed(page.read_text(encoding="utf-8"))
        for link in parser.found:
            path = relative(link)
            if path is None:
                continue
            checked += 1
            target = (page.parent / path).resolve()
            if target.is_dir():
                target = target / "index.html"
            if not target.is_relative_to(site) or not target.is_file():
                broken.append(f"{page.relative_to(site)}: {link}")
    for b in broken:
        print(f"FAIL  broken link  {b}")
    print(f"  {len(pages)} pages, {checked} relative links, {len(broken)} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
