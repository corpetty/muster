#!/usr/bin/env python3
"""Keep the "how to run it" instructions from rotting past what actually builds.

The failure this guards: the README (or someone's memory) says `make run` /
`nix run` launches the standalone app, while the Makefile target or the flake
output it leans on has been renamed or removed — so the one command a newcomer
tries fails, and nothing warned. Same house pattern as check-readme-rot.py and
check-claims-registry.py: resolution FAILs, text-only so it is pre-commit cheap
(it deliberately does NOT `nix eval`, which would be slow and needs the network).

  FAIL  the root Makefile is missing a target the docs/help promise
  FAIL  ui/flake.nix does not expose the standalone runner (mkLogosQmlModule +
        a `runner` package) that `make run` / `make build` resolve to
  FAIL  the README's run section stops naming `make run`

What it can prove is that the pieces line up; it cannot prove the app renders —
that is the ui/tests harness (basecamp) and the standalone driver. This is the
cheap gate that stops the docs and the build config from drifting apart.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = REPO_ROOT / "Makefile"
UI_FLAKE = REPO_ROOT / "ui" / "flake.nix"
README = REPO_ROOT / "README.md"

# Targets the root Makefile must carry — the ones `help` advertises and the docs
# tell people to run.
REQUIRED_TARGETS = {"run", "build", "build-lgx", "clean", "help"}

TARGET_RE = re.compile(r"^([a-zA-Z][a-zA-Z0-9_-]*):", re.MULTILINE)


def check() -> list[str]:
    failures: list[str] = []

    if not MAKEFILE.exists():
        return [f"no root Makefile at {MAKEFILE.name} — `make run` cannot work"]
    make_text = MAKEFILE.read_text(encoding="utf-8")
    targets = set(TARGET_RE.findall(make_text))
    for t in sorted(REQUIRED_TARGETS - targets):
        failures.append(f"Makefile: no `{t}` target — the docs/help promise `make {t}`")

    # `make run` resolves apps.default (the standalone runner from
    # mkLogosQmlModule); `make build` resolves the `.#runner` package.
    if not UI_FLAKE.exists():
        failures.append("ui/flake.nix is missing — the run targets have nothing to build")
    else:
        flake = UI_FLAKE.read_text(encoding="utf-8")
        if "mkLogosQmlModule" not in flake:
            failures.append(
                "ui/flake.nix no longer uses mkLogosQmlModule — that is what provides "
                "apps.default (the standalone runner `make run`/`nix run` launch)"
            )
        if not re.search(r"\brunner\b\s*=", flake):
            failures.append(
                "ui/flake.nix declares no `runner` package — `make build` "
                "(nix build .#runner) will not resolve"
            )

    if README.exists() and "make run" not in README.read_text(encoding="utf-8"):
        failures.append(
            "README.md no longer tells people to `make run` — the run instructions "
            "have drifted from the Makefile"
        )

    return failures


def main() -> int:
    failures = check()
    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        print(f"\n{len(failures)} failure(s).")
        return 1
    print("run targets OK — Makefile targets, the ui runner output, and the README agree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
