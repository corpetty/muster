#!/usr/bin/env python3
"""Validate the action corpus (exo-661) — contracts/actions/.

The corpus is every action a person can take in Muster, in full detail, and the atlas
(docs/design/multisig-atlas.html, served at /atlas/) renders it. The failure it exists
for is the one the figures and READMEs had: a page that keeps rendering, keeps looking
authoritative, and describes a system that changed. So a built action's machine facts
are generated from the code (contracts/actions/generated.json, held by a golden test),
and everything authored around them must resolve: a family that exists, a vocabulary
value the code uses, a test that is on disk, a hosted method the contract declares.
CI cannot check that the narrative is TRUE — that is the author's obligation, with the
evidence it cites. Design: docs/design/action-atlas.md.

  FAIL  a file that does not parse, or generated.json missing
  FAIL  a duplicate action id, or a required field missing
  FAIL  a value outside a closed vocabulary (area, status, step, when, observer,
        requirement kind / party / class, touch mode, credibility)
  FAIL  a family action whose family is not in the registry, is not the file's family,
        or whose status disagrees with the family's (built → built; partial →
        partial; candidate → declared; watch / reject → no actions at all)
  FAIL  a built/partial family proposal with no generated entry, or one that restates
        the generated machine fields (agreement / requirements / touches / disclosure)
  FAIL  a declared action with no primary source, or with a generated key or hosted methods
  FAIL  a room / wallet / setup action without its own requirements and disclosure
  FAIL  an evidence, step or refusal path that is not on disk (built / partial)
  FAIL  a hosted method that module/src/api/muster.lidl does not declare
  FAIL  a built, partial or candidate family with no actions
  FAIL  the corpus embedded in the atlas is out of date (--write refreshes it)
  WARN  an action carrying `unverified` claims (listed, so they are not forgotten)
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ACTIONS = ROOT / "contracts" / "actions"
GENERATED = ACTIONS / "generated.json"
REGISTRY = ROOT / "contracts" / "families" / "registry.json"
LIDL = ROOT / "module" / "src" / "api" / "muster.lidl"
ATLAS = ROOT / "docs" / "design" / "multisig-atlas.html"
BEGIN, END = "<!-- actions-json:begin -->", "<!-- actions-json:end -->"

AREA = {"family", "room", "wallet"}
STATUS = {"built", "partial", "declared"}
STEP = {"propose", "approve", "ceremony", "vote", "settle", "final", "act"}
WHEN = {"propose", "approve", "settle", "final", "act", "always"}
OBSERVER = {"room-member", "store-node", "rpc-provider", "chain-observer", "target-module"}
REQ_KIND = {"module", "environment", "authority", "infra", "capability", "address", "asset"}
PARTY = {"instance", "proposer", "contributor", "counterparty"}
CLASS = {"authority", "address", "asset", "infra", "capability"}
MODE = {"read", "write"}
CRED = {"imperative", "motivational", "exposed", "not-applicable"}
MACHINE = ("agreement", "requirements", "touches", "disclosure")
# a family's registry status → the status its actions carry
FAMILY_STATUS = {"built": {"built"}, "partial": {"partial", "built"}, "candidate": {"declared"}}


def authored_files() -> list[Path]:
    return sorted((ACTIONS / "family").glob("*.json")) + [p for p in (ACTIONS / "room.json", ACTIONS / "wallet.json") if p.exists()]


def load(path: Path, fails: list[str]):
    try:
        return json.loads(path.read_text())
    except Exception as e:  # noqa: BLE001 — any parse failure is a FAIL
        fails.append(f"{path.relative_to(ROOT)}: does not parse ({e})")
        return None


def exists(p: str) -> bool:
    return bool(p) and (ROOT / p).exists()


def corpus_for_atlas(generated: dict, files: dict[str, list[dict]]) -> dict:
    """What the atlas embeds: the generated machine facts and every authored action,
    in file order — the page joins a built action to its generated entry itself."""
    actions = []
    for rel, acts in files.items():
        for a in acts:
            actions.append(dict(a, source=rel))
    return {"generated": generated.get("entries", {}), "actions": actions}


def spliced_atlas(corpus: dict) -> tuple[str, str]:
    page = ATLAS.read_text()
    if BEGIN not in page or END not in page:
        return page, page
    i, j = page.index(BEGIN) + len(BEGIN), page.index(END)
    data = json.dumps(corpus, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    block = '\n<script id="actions" type="application/json">' + data + "</script>\n"
    return page, page[:i] + block + page[j:]


def check_rows(where: str, a: dict, fails: list[str]) -> None:
    for r in a.get("requirements", []):
        if r.get("kind") not in REQ_KIND: fails.append(f"{where}: requirement kind {r.get('kind')!r}")
        if r.get("party", "instance") not in PARTY: fails.append(f"{where}: requirement party {r.get('party')!r}")
        if r.get("class") and r["class"] not in CLASS: fails.append(f"{where}: requirement class {r.get('class')!r}")
    for t in a.get("touches", []):
        if t.get("mode") not in MODE: fails.append(f"{where}: touch mode {t.get('mode')!r}")
    for d in a.get("disclosure", []):
        if d.get("observer") not in OBSERVER: fails.append(f"{where}: observer {d.get('observer')!r}")
        if d.get("when", "always") not in WHEN: fails.append(f"{where}: when {d.get('when')!r}")


def main() -> int:
    fails: list[str] = []
    warns: list[str] = []
    reg = json.loads(REGISTRY.read_text())
    families = {f["id"]: f for f in reg["families"]}
    lidl_methods = set(re.findall(r"^\s*method\s+([a-z_][a-z0-9_]*)\s*\(", LIDL.read_text(), re.M))

    generated = load(GENERATED, fails) if GENERATED.exists() else None
    if generated is None:
        fails.append(f"{GENERATED.relative_to(ROOT)}: missing — run module/tools/action_corpus.nim --write")
        generated = {"entries": {}}
    entries = generated.get("entries", {})

    files: dict[str, list[dict]] = {}
    for path in authored_files():
        doc = load(path, fails)
        if doc is None: continue
        acts = doc.get("actions")
        if not isinstance(acts, list) or not acts:
            fails.append(f"{path.relative_to(ROOT)}: no `actions` list"); continue
        files[str(path.relative_to(ROOT))] = acts

    seen: set[str] = set()
    has_actions: set[str] = set()
    for rel, acts in files.items():
        file_family = Path(rel).stem if "/family/" in rel else None
        for a in acts:
            aid = a.get("id", "<no id>")
            where = f"{rel}: {aid}"
            if aid in seen: fails.append(f"{where}: duplicate id")
            seen.add(aid)
            for k in ("id", "name", "area", "status", "summary", "steps", "evidence", "invariants"):
                if not a.get(k): fails.append(f"{where}: missing `{k}`")
            area, status = a.get("area"), a.get("status")
            if area not in AREA: fails.append(f"{where}: area {area!r}")
            if status not in STATUS: fails.append(f"{where}: status {status!r}")
            if any(not isinstance(i, int) or not 1 <= i <= 10 for i in a.get("invariants", [])):
                fails.append(f"{where}: invariants must be numbers 1–10")
            for c in a.get("claims", []):
                if c.get("credibility") not in CRED: fails.append(f"{where}: credibility {c.get('credibility')!r}")
            for s in a.get("steps", []):
                if s.get("step") not in STEP: fails.append(f"{where}: step {s.get('step')!r}")
                for r in s.get("reveals", []):
                    if r.get("observer") not in OBSERVER: fails.append(f"{where}: step reveals observer {r.get('observer')!r}")
            gen = a.get("generated")
            machine_present = [k for k in MACHINE if k in a]
            # ── area-specific rules ──────────────────────────────────────────────
            if area == "family":
                fam = a.get("family")
                if file_family is None or fam != file_family:
                    fails.append(f"{where}: family {fam!r} is not this file's family ({file_family!r})")
                if not str(aid).startswith(f"{fam}/"):
                    fails.append(f"{where}: a family action's id starts with '<family>/'")
                entry = families.get(fam)
                if entry is None:
                    fails.append(f"{where}: family {fam!r} is not in the registry")
                else:
                    fstatus = entry.get("muster", {}).get("status")
                    allowed = FAMILY_STATUS.get(fstatus)
                    if allowed is None:
                        fails.append(f"{where}: family {fam} is '{fstatus}' — watch / reject families carry no actions")
                    elif status not in allowed:
                        fails.append(f"{where}: status {status!r}, but family {fam} is '{fstatus}' (want {sorted(allowed)})")
                    has_actions.add(fam)
                if status in ("built", "partial") and gen:
                    if gen not in entries: fails.append(f"{where}: generated entry {gen!r} not in generated.json")
                    if machine_present:
                        fails.append(f"{where}: restates generated machine fields {machine_present} — they come from {gen!r}")
                    if entries.get(gen, {}).get("family") not in (None, fam):
                        fails.append(f"{where}: generated entry {gen!r} is family {entries[gen].get('family')!r}")
            elif a.get("family"):
                fails.append(f"{where}: a {area} action names no family")
            # ── what each kind of action must carry ──────────────────────────────
            if status == "declared":
                if gen: fails.append(f"{where}: a declared action has no generated entry")
                if a.get("hosted"): fails.append(f"{where}: a declared action has no hosted methods")
                if not any(e.get("kind") == "source" and e.get("url") for e in a.get("evidence", [])):
                    fails.append(f"{where}: a declared action needs a primary source")
                for k in MACHINE:
                    if k not in a: fails.append(f"{where}: a declared action carries `{k}`")
            elif not gen:
                for k in ("requirements", "disclosure"):
                    if k not in a: fails.append(f"{where}: a room / wallet / setup action carries its own `{k}`")
            check_rows(where, a, fails)
            # ── evidence resolves ─────────────────────────────────────────────────
            if status in ("built", "partial"):
                for e in a.get("evidence", []):
                    if e.get("kind") == "test" and not exists(e.get("path", "")):
                        fails.append(f"{where}: evidence {e.get('path')!r} is not on disk")
                    if e.get("kind") == "source" and not e.get("url"):
                        fails.append(f"{where}: a source evidence entry needs a url")
                for s in a.get("steps", []) + a.get("refusals", []):
                    for p in s.get("evidence", []):
                        if not exists(p): fails.append(f"{where}: evidence {p!r} is not on disk")
                for m in a.get("hosted", []):
                    if m not in lidl_methods: fails.append(f"{where}: hosted method {m!r} is not in muster.lidl")
            if a.get("unverified"):
                warns.append(f"{where}: {len(a['unverified'])} unverified claim(s)")

    for fid, f in families.items():
        if f.get("muster", {}).get("status") in FAMILY_STATUS and fid not in has_actions:
            fails.append(f"contracts/actions/family/{fid}.json: family {fid} is "
                         f"'{f['muster']['status']}' but has no actions")

    corpus = corpus_for_atlas(generated, files)
    page, new = spliced_atlas(corpus)
    if BEGIN not in page:
        fails.append(f"{ATLAS.relative_to(ROOT)}: no {BEGIN} marker to embed the corpus into")
    elif "--write" in sys.argv:
        if new != page:
            ATLAS.write_text(new)
            print(f"wrote the corpus into {ATLAS.relative_to(ROOT)}")
    elif new != page:
        fails.append(f"{ATLAS.relative_to(ROOT)}: embedded corpus is out of date — run {Path(__file__).name} --write")

    for w in warns: print(f"WARN  {w}")
    for f in fails: print(f"FAIL  {f}")
    n = sum(len(v) for v in files.values())
    by = {}
    for acts in files.values():
        for a in acts: by[a.get("status")] = by.get(a.get("status"), 0) + 1
    print(f"action corpus: {n} actions in {len(files)} files · "
          + " · ".join(f"{k} {v}" for k, v in sorted(by.items())) + f" · {len(entries)} generated entries")
    if fails:
        print(f"{len(fails)} failure(s)")
        return 1
    print("action corpus OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
