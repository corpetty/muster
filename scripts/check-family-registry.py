#!/usr/bin/env python3
"""Validate the multisig family registry (exo-68f) — contracts/families/registry.json.

The registry is the data behind "every multisig feels the same, and the card shows
how they differ" (docs/design/multisig-landscape.md). Its fields feed fixed card
slots, so a value outside the closed vocabulary would render as a slot with nothing
honest to say, and an entry whose fields contradict each other would teach the wrong
consequence. CI cannot check that an entry is TRUE — that is the author's obligation,
with a primary source per entry. It can check that the entry is well-formed, that
its fields agree with each other, and that what we claim to have built exists.

  FAIL  a field value outside the vocabulary declared in `about.vocabulary`
  FAIL  a duplicate family id
  FAIL  a family with no `muster.why` (every status carries its reason)
  FAIL  a built/partial family whose `muster.driver` is missing or not on disk
  FAIL  a `phase` on a family that is not next / candidate / partial
  FAIL  a chain family (settlement != none) with no primary `sources`
  FAIL  expiry=forced with no `expiryWindow`
  FAIL  the locus/scheme/binding/cost/reveal rules disagree (see check_consistency)
  FAIL  a built/partial/next family whose chain signature has binding=none but
        names no `exposure` — invariant 2 cannot hold at the chain layer there, so
        the card must say who could replay it, never stay silent
  FAIL  the landscape table in docs/design/multisig-landscape.md, or the registry
        embedded in docs/design/multisig-atlas.html, is out of date with the
        registry (regenerate both: scripts/check-family-registry.py --write-table)
  WARN  an entry carries `unverified` items (listed, so they are not forgotten)
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "contracts" / "families" / "registry.json"
DOC = ROOT / "docs" / "design" / "multisig-landscape.md"
BEGIN, END = "<!-- landscape-table:begin -->", "<!-- landscape-table:end -->"
EXPLORER = ROOT / "docs" / "design" / "multisig-atlas.html"
EBEGIN, EEND = "<!-- registry-json:begin -->", "<!-- registry-json:end -->"

VOCAB_FIELDS = ["locus", "scheme", "commits", "binding", "ordering", "expiry",
                "setup", "membershipChange", "approverCost"]


def vocab_keys(v) -> set[str]:
    return set(v.keys()) if isinstance(v, dict) else set(v)


def check_consistency(f: dict) -> list[str]:
    """The rules that keep a family's fields telling one story."""
    errs = []
    locus, scheme = f.get("locus"), f.get("scheme")
    rv = f.get("reveals", {})
    room = locus == "room"
    if room != (f.get("settlement") == "none"):
        errs.append("locus=room iff settlement=none")
    if room != (f.get("binding") == "room"):
        errs.append("locus=room iff binding=room")
    if (locus == "aggregate") != str(scheme).startswith("aggregate-"):
        errs.append("locus=aggregate iff scheme=aggregate-*")
    if (locus == "vote") != (scheme == "own-transaction"):
        errs.append("locus=vote iff scheme=own-transaction")
    if (locus == "vote") != str(f.get("approverCost")).startswith("per-vote"):
        errs.append("locus=vote iff approverCost=per-vote*")
    if f.get("commits") == "pointer" and locus != "vote":
        errs.append("a pointer-only approval exists only where each approval is its own transaction (vote)")
    if locus == "aggregate" and (rv.get("policy") != "never" or rv.get("signers") != "never"):
        errs.append("an aggregate signature reveals neither policy nor signers on-chain")
    if "per-approval" in (rv.get("policy"), rv.get("signers")) and locus != "vote":
        errs.append("reveals per-approval only when approvals are on-chain (vote)")
    if room and (rv.get("policy") != "never" or rv.get("signers") != "never"
                 or rv.get("effect") not in ("room-only", "target-module")):
        errs.append("a room family reveals nothing to a chain")
    if rv.get("effect") == "target-module" and not room:
        errs.append("target-module visibility is a room family's")
    if f.get("secretState") and int(f.get("rounds", 1)) < 2:
        errs.append("secret nonce state implies at least 2 rounds")
    if f.get("setup") == "dkg" and scheme != "aggregate-threshold":
        errs.append("a DKG ceremony is only needed for threshold aggregation")
    return errs


def landscape_table(reg: dict) -> str:
    """The doc's §3 table, one row per family — generated, never hand-edited."""
    when = {"never": "–", "at-creation": "setup", "per-approval": "each vote", "at-settle": "spend"}
    eff = {"public": "public", "shielded": "**shielded**", "room-only": "room only", "target-module": "the module it calls"}
    cost = {"none": "–", "per-signature": "per sig", "per-vote": "a tx", "per-vote-deposit": "a tx + deposit"}
    sch = {"shared-bytes": "same bytes", "per-signer-bytes": "**own blob each**", "own-transaction": "own tx",
           "aggregate-n-of-n": "partial (n-of-n)", "aggregate-threshold": "partial (t-of-n)"}
    rows = ["| Family | Locus | Signs | Binding | Rounds · setup | Signer change | "
            "Chain learns policy / signers / effect | Ordering · expiry | Approver pays | Maturity | Muster |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    for f in reg["families"]:
        rv, m = f["reveals"], f["muster"]
        signs = sch.get(f["scheme"], f["scheme"]) + (" → **pointer**" if f["commits"] == "pointer" else "")
        binding = "**none**" if f["binding"] == "none" else f["binding"]
        window = f.get("expiryWindow", "").split(";")[0].split("(")[0].strip()
        expiry = f["expiry"] + (f" ({window})" if window else "")
        rounds = f"{f['rounds']}{' ⚿' if f['secretState'] else ''} · {f['setup']}"
        status = m["status"] + (f" ({m['phase']})" if m.get("phase") else "")
        rows.append(f"| `{f['id']}` | {f['locus']} | {signs} | {binding} | {rounds} | {f['membershipChange']} | "
                    f"{when.get(rv['policy'], rv['policy'])} / {when.get(rv['signers'], rv['signers'])} / "
                    f"{eff.get(rv['effect'], rv['effect'])} | {f['ordering']} · {expiry} | "
                    f"{cost.get(f['approverCost'], f['approverCost'])} | {f['maturity']} | {status} |")
    return "\n".join(rows)


def spliced_doc(reg: dict) -> tuple[str, str]:
    doc = DOC.read_text()
    i, j = doc.index(BEGIN) + len(BEGIN), doc.index(END)
    return doc, doc[:i] + "\n" + landscape_table(reg) + "\n" + doc[j:]


def spliced_explorer(reg: dict) -> tuple[str, str]:
    """The explorer page carries the registry verbatim, so it can never drift from it."""
    page = EXPLORER.read_text()
    i, j = page.index(EBEGIN) + len(EBEGIN), page.index(EEND)
    data = json.dumps(reg, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    block = '\n<script id="registry" type="application/json">' + data + "</script>\n"
    return page, page[:i] + block + page[j:]


def main() -> int:
    reg = json.loads(REGISTRY.read_text())
    if "--write-table" in sys.argv:
        _, new = spliced_doc(reg)
        DOC.write_text(new)
        _, page = spliced_explorer(reg)
        EXPLORER.write_text(page)
        print(f"wrote the landscape table into {DOC.relative_to(ROOT)} and the registry into {EXPLORER.relative_to(ROOT)}")
    vocab = reg["about"]["vocabulary"]
    fails: list[str] = []
    warns: list[str] = []
    seen: set[str] = set()
    for f in reg["families"]:
        fid = f.get("id", "<no id>")
        if fid in seen:
            fails.append(f"{fid}: duplicate id")
        seen.add(fid)
        for field in VOCAB_FIELDS:
            if f.get(field) not in vocab_keys(vocab[field]):
                fails.append(f"{fid}: {field}={f.get(field)!r} not in the vocabulary")
        for k in ("policy", "signers"):
            if f.get("reveals", {}).get(k) not in vocab_keys(vocab["reveal"]):
                fails.append(f"{fid}: reveals.{k} not in the vocabulary")
        if f.get("reveals", {}).get("effect") not in vocab_keys(vocab["effectVisibility"]):
            fails.append(f"{fid}: reveals.effect not in the vocabulary")
        if f.get("maturity") not in vocab["maturity"]:
            fails.append(f"{fid}: maturity={f.get('maturity')!r} not in the vocabulary")
        if f.get("settlement") not in vocab["settlement"]:
            fails.append(f"{fid}: settlement={f.get('settlement')!r} not in the vocabulary")
        m = f.get("muster", {})
        status = m.get("status")
        if status not in vocab_keys(vocab["status"]):
            fails.append(f"{fid}: muster.status={status!r} not in the vocabulary")
        if not m.get("why"):
            fails.append(f"{fid}: muster.why is empty — every status carries its reason")
        if status in ("built", "partial"):
            drv = m.get("driver")
            if not drv or not (ROOT / drv).is_file():
                fails.append(f"{fid}: status={status} but driver {drv!r} is not on disk")
        if "phase" in m and status not in ("next", "candidate", "partial"):
            fails.append(f"{fid}: phase on a {status} family")
        if f.get("settlement") != "none" and not f.get("sources"):
            fails.append(f"{fid}: a chain family needs primary sources")
        if f.get("expiry") == "forced" and not f.get("expiryWindow"):
            fails.append(f"{fid}: expiry=forced needs an expiryWindow")
        if f.get("binding") == "none" and status in ("built", "partial", "next") and not f.get("exposure"):
            fails.append(f"{fid}: binding=none on a {status} family needs an `exposure` naming the replay risk")
        fails += [f"{fid}: {e}" for e in check_consistency(f)]
        for u in f.get("unverified", []):
            warns.append(f"{fid}: unverified — {u}")

    try:
        cur, new = spliced_doc(reg)
        if cur != new:
            fails.append(f"{DOC.relative_to(ROOT)}: landscape table is out of date — run {Path(__file__).name} --write-table")
    except (FileNotFoundError, ValueError):
        fails.append(f"{DOC.relative_to(ROOT)}: missing, or its landscape-table markers are gone")
    try:
        cur, new = spliced_explorer(reg)
        if cur != new:
            fails.append(f"{EXPLORER.relative_to(ROOT)}: embedded registry is out of date — run {Path(__file__).name} --write-table")
    except (FileNotFoundError, ValueError):
        fails.append(f"{EXPLORER.relative_to(ROOT)}: missing, or its registry-json markers are gone")

    fams = reg["families"]
    by_status = Counter(f.get("muster", {}).get("status") for f in fams)
    by_locus = Counter(f.get("locus") for f in fams)
    for w in warns:
        print(f"WARN  {w}")
    for e in fails:
        print(f"FAIL  {e}")
    print(f"family registry: {len(fams)} families · status "
          + ", ".join(f"{k} {v}" for k, v in sorted(by_status.items()))
          + " · locus " + ", ".join(f"{k} {v}" for k, v in sorted(by_locus.items())))
    if fails:
        print(f"family registry FAILED — {len(fails)} problem(s)")
        return 1
    print("family registry OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
