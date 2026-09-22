## Schema-driven rendering (exo-1ec.3, docs/00-vision honesty rules): an activity
## renders ONLY from a declared, versioned schema. An `effect` muster has no schema for
## — or a malformed one — must surface a NAMED "schema unknown" failure, never a silent
## coercion to a transfer or a blank pane. v0 uses hand-assigned ids (ADR-009), so
## "known" is membership in the v0 vocabulary, not a parsed CDDL root. This is the
## RENDERING gate: the intent view carries schemaId + schemaKnown; the card renders the
## failure when known is false. Pure Nim (stub driver).

import std/strutils
import ../src/drivers/driver
import ../src/coordination/intents

# ── 1. effectSchema recognizes the v0 vocabulary and NAMES the unknown ────────────
block:
  doAssert effectSchema("""{"to":"0xabc","value":5}""") == ("muster.effect.transfer.v1", true),
    "a legacy plain transfer (no effect field) is a known schema"
  doAssert effectSchema("""{"effect":"transfer","to":"0x0","value":1}""").known
  doAssert effectSchema("""{"effect":"statement","text":"hi"}""") == ("muster.effect.statement.v1", true)
  doAssert effectSchema("""{"effect":"add-driver","kind":"frost"}""").known
  doAssert effectSchema("""{"effect":"invoke","module":"lez_core","method":"transfer_private"}""") ==
    ("muster.invoke.lez_core.transfer_private.v1", true), "the invoke family is a declared schema"
  # the UNKNOWN cases — named, never coerced:
  let bogus = effectSchema("""{"effect":"frobnicate","x":1}""")
  doAssert not bogus.known, "an effect muster has no schema for is unknown"
  doAssert bogus.id.contains("frobnicate"), "the unknown id NAMES what was declared: " & bogus.id
  doAssert not effectSchema("""{"effect":"invoke"}""").known, "a malformed invoke (no module/method) is unknown"
  doAssert not effectSchema("not json at all").known, "malformed JSON is a named unknown, not a silent transfer"
  doAssert not effectSchema("""["an","array"]""").known, "a non-object effect is unknown"
  echo "1. effectSchema recognizes the v0 vocabulary and names the unknown OK"

# ── 2. the intent view carries the schema recognition, so the card can gate render ─
block:
  let stub: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, membership = mmNamed, verifyResult = true)
  # a KNOWN activity: the view renders it as itself.
  let knownJson = """{"effect":"statement","text":"the room agrees"}"""
  let kId = intentIdFor(knownJson)
  let kViews = reduceIntentViews(@[proposeEvent(kId, knownJson)], stub)
  doAssert kViews.len == 1 and kViews[0].schemaKnown, "a declared schema renders as itself"
  doAssert kViews[0].schemaId == "muster.effect.statement.v1"
  # an UNKNOWN activity: the view flags it, and NAMES the schema, instead of rendering it
  # as a (wrong) transfer — the card draws a "schema unknown" failure from this.
  let badJson = """{"effect":"frobnicate","to":"0xdead"}"""
  let bId = intentIdFor(badJson)
  let bViews = reduceIntentViews(@[proposeEvent(bId, badJson)], stub)
  doAssert bViews.len == 1, "the unknown activity still appears (no blank pane) — as a failure"
  doAssert not bViews[0].schemaKnown, "the view flags the unknown schema"
  doAssert bViews[0].schemaId.contains("frobnicate"), "the view names the declared schema"
  echo "2. reduceIntentViews carries schemaKnown so the card renders the named failure OK"

echo "schema_unknown_test: all OK"
