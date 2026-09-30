## The action corpus's golden test (docs/design/action-atlas.md §4, exo-661 A2): the
## generated half of the atlas — contracts/actions/generated.json — must be exactly what
## the running drivers say today (module/tools/action_corpus.nim). A driver whose
## describe / profile / manifest / environment / signRefusal changes fails here until the
## file is regenerated, so the atlas cannot drift from the code. Also held:
##   * the entry keys are exactly the fixed list the authored corpus is written against;
##   * every entry's manifest is declared (an undeclared manifest has no place in a
##     corpus of BUILT actions — it would be shown as undeclared, never guessed);
##   * two runs of the generator give the same bytes (determinism).
## `--write` (TEST_ARGS=--write module/tests/run-suite.sh action_corpus) rewrites the
## file first. Needs the full closure (secp, stint, web3, libsodium) — the runner's flags.

import std/[json, os, sets, strutils]
import ../tools/action_corpus

const Fixed = ["safe/transfer", "safe/contract-call", "safe/delegatecall",
               "threshold/statement", "threshold/add-driver", "unanimous/statement",
               "frost/statement", "eip191/statement",
               "invoke/module-call", "invoke/lez-transfer",
               "btc-p2wsh/spend", "btc-tapscript/spend", "btc-frost/spend",
               "lez-multisig/transfer", "lez-multisig/vault-init", "lez-frost/transfer",
               "evm-split/split", "evm-split/settle-up", "lez-split/split", "btc-split/split",
               "btc-split/settle-up"]
const EntryFields = ["kind", "variant", "family", "effectExample", "describe", "environment",
                     "profile", "manifest", "signRefusal"]

if "--write" in commandLineParams():
  writeCorpus()
  echo "wrote ", GeneratedPath.normalizedPath()

let generated = corpus()

# ── 1. the committed file is what the drivers say today ───────────────────────
block:
  doAssert fileExists(GeneratedPath),
    "contracts/actions/generated.json is missing — generate it with: " & RegenerateCommand
  let committed = parseJson(readFile(GeneratedPath))
  if generated != committed:
    var stale: seq[string]
    for k, v in generated["entries"]:
      if not committed{"entries"}.hasKey(k) or committed["entries"][k] != v: stale.add k
    if committed{"entries"} != nil:
      for k, _ in committed["entries"]:
        if not generated["entries"].hasKey(k): stale.add k & " (no longer generated)"
    if generated["about"] != committed{"about"}: stale.add "about"
    doAssert false, "contracts/actions/generated.json is stale (" & stale.join(", ") &
      ") — the drivers changed; regenerate it with: " & RegenerateCommand
  echo "1. contracts/actions/generated.json equals what the drivers say today OK"

# ── 2. exactly the fixed keys, every entry complete and declared ──────────────
block:
  var keys: HashSet[string]
  for k, _ in generated["entries"]: keys.incl k
  doAssert keys == toHashSet(Fixed), "the generated keys are the fixed list (§3a): got " & $keys
  for k, e in generated["entries"]:
    for f in EntryFields: doAssert e.hasKey(f), k & " lacks " & f
    doAssert e.len == EntryFields.len, k & " carries a key outside §3a's entry format"
    doAssert k == e["kind"].getStr() & "/" & e["variant"].getStr(), k & ": key is not kind/variant"
    doAssert e["manifest"]["declared"].getBool(), k & ": the manifest is undeclared"
    doAssert e["profile"]["declared"].getBool(), k & ": the profile is undeclared"
    doAssert e["profile"]["family"].getStr() == e["family"].getStr(), k & ": family disagrees with the profile"
  # the one refusal the corpus is built to show: an un-allowlisted delegatecall
  for k, e in generated["entries"]:
    if k == "safe/delegatecall": doAssert "delegatecall" in e["signRefusal"].getStr(), "a delegatecall is refused"
    else: doAssert e["signRefusal"].getStr() == "", k & " is refused: " & e["signRefusal"].getStr()
  echo "2. the ", Fixed.len, " fixed keys, each a complete entry with a declared manifest and profile OK"

# ── 3. deterministic: the same bytes every run ────────────────────────────────
block:
  doAssert corpusText() == corpusText(), "the corpus must be the same bytes every run"
  doAssert corpusText() == readFile(GeneratedPath),
    "contracts/actions/generated.json is not the generator's exact bytes (edited or reformatted by hand?) — " &
    "regenerate it with: " & RegenerateCommand
  echo "3. the generator is deterministic OK"

echo "action_corpus_test: all OK"
