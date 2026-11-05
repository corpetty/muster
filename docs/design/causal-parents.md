# Causal order: events that say what they followed (exo-655, epic exo-dde)

**Status:** C1–C4 built 2026-10-11, with §5's decisions as recommended (an annotation outside identity; the room map and the activity feed move to causal order). C5, the author signing `after`, built 2026-10-12 (§7a). Tests: `causal_order_test`, `after_state_test`, `causal_publish_test`, `after_signed_test`, `room_graph_test` §11.
**Reads with:** [room-map.md](room-map.md) §9 (why replay is not chronology yet); `log/log.nim` (the log and its order); `coordination/attest.nim` and `coordination/audit.nim` (the code that relies on `parents` as it is); spec `derived-exo-403` (the audit file).
**Paths:** short paths are under `module/src/`.

## 1. The problem

`CoordinationSession.publish` sends each event with the parents its caller chose. Production code sets parents in only two places: an approval names the proposal and the approvals already counted, and an attestation names its approval. Every other event (proposals, messages, context, reads, part reports, submits, admissions) is a root.

`canonicalOrder` places an event after its parents and breaks ties by smallest content id. With most events as roots, canonical order is content-id order. So nothing that reads the log can say what happened in what order. The room map's replay shows this: within an epoch its order is arbitrary, and a proposal's state can only be shown as it ends. The activity feed hits the same wall (`intents.nim:663`: canonical order "scrambles a proposal's lifecycle").

The ask: make events say what their publisher had seen, so a view can replay the room in the order it happened.

## 2. Why not just fill in `parents`

The obvious change is for `publish` to set every new event's `parents` to the log's current heads. That breaks four mechanisms that depend on `parents` and on content ids as they are now.

1. **The signed provenance record (invariant 10).** `intentInputs` cites each input's content id (`logRef`), and the attestation signs a record built from those ids. Today a re-announced proposal is rebuilt with empty parents and gets the same id, so every member derives the same record. With heads in `parents`, the copy's id differs. The record then names two proposals, or names different ones on different devices.
2. **An intent's record (exo-093, exo-dc6).** An approval copy is kept only if every parent is in the intent's lineage or is a kept copy, and an attestation is admitted only if its parents are in the record. Heads would put unrelated room events into those parents, so honest approvals would stop counting.
3. **The audit file (derived-exo-403).** An intent's lineage is the closure over `parents` from its inputs, and the export is refused when the lineage reaches an event the exporter cannot read. With heads, an input's lineage would reach back through every earlier room event. Every later joiner's export would be refused, and spec s5's scenarios would change meaning.
4. **Idempotent re-publishing.** `liveReannounce` rebuilds the policy and proposal and relies on getting the same ids. A second submit for the same transaction relies on identical bytes to fold once. With heads, both would create new events.

Each of these is right as built. `parents` means **lineage**: what an entry's meaning depends on, checked by the code that guards invariants 1, 2 and 10. It is a different relation from **causal order**, what the publisher had seen. The design keeps them apart.

## 3. The proposal: `after`, an ordering annotation outside identity

Each event gains a second, optional list, `after`: the heads of the publisher's log when it published.

```
Event = { parents, key, value, after }      # after: seq[EventId], usually 1–3 ids
eventId(e) = digest("muster.event.v1", parents, key, value)   # unchanged: after is not in it
```

**`after` is not part of the event's identity.** Every mechanism in §2 keeps the ids it has today:
- the provenance record,
- an intent's record,
- the audit file and log proofs,
- re-announce and re-publishing.

None of them reads `after`, and no test that pins an id from an empty-parent constructor changes.

**`after` never reaches state.** `canonicalOrder` and every fold keep reading `parents` alone, so `state = reduce(log)` is untouched. A new order reads both:

```
causalOrder(events) — a topological order over parents (hard edges) ∪ after (soft edges),
                      ties by smallest content id; for views only
```

The room map, its replay and the activity feed move to `causalOrder`. Folds, signing paths, the audit and proofs stay on `canonicalOrder`. So no member can change what the room agreed to by writing a misleading `after`; the worst it can do is reorder what a view shows.

### 3.1 Two rules make it converge

`after` is outside the id, so two copies of one event can carry different `after` lists. That happens when a member re-publishes without its stored copy, or when two devices publish the same event independently. State must stay a function of the event set (invariant 4), so the order must not depend on which copy arrived first.

1. **One copy wins, chosen by content.** For each id the log keeps the variant whose `after` list (sorted) has the smallest digest under `muster.event.after.v1`. That choice is commutative and associative, so every device that holds the same variants keeps the same one, whatever their arrival order.
2. **A soft edge never closes a cycle.** `parents` cannot form a cycle, because a parent's id exists before its child. An `after` edge can. A variant published by a device that held a descendant of the event but not the event itself (a joiner holds dangling parents) can point forward. `causalOrder` therefore adds soft edges one at a time, in a deterministic order (by child id, then target id), and skips any edge that would close a cycle. Every event is always emitted. A skipped edge only loses a little ordering.

### 3.2 What publishing does

`publish` stamps `after` and keeps everything else:

- **A new event:** `after` = the heads of the log, meaning events no other held event names through `parents` or `after` (`Log.heads`). At most 8; past that, the 8 latest in causal order, which in practice never happens. Callers keep setting `parents` exactly as now.
- **An event the log already holds** (same id): re-seal the **stored** copy, with its original `after`. Re-announce then carries the true order to a joiner instead of a fresh one. This also covers the second submit and re-proposing the same effect. For an author-bearing event, `publishAuthored` re-seals the copy whose `after` its author signed, not whichever copy the log keeps, which any member who received the event can plant (`authorship.copyToSeal`, docs/design/voice-notes.md §4).
- **Author-signed events:** `claimOf` signs `parents`, not `after`. So `publishAuthored` signs as now and `publish` stamps `after` afterwards, without breaking the signature. §5 covers whether `after` should be signed.

### 3.3 The wire

`encodeEvent` writes `"after"` only when it is non-empty, and `decodeEvent` reads it if present. A client from before this change ignores the field and computes the same id. Parentless events from older clients have empty `after` and sort as they do now. So old and new clients can share a room, and no flag day is needed.

### 3.4 Epochs

`after` may name events of an earlier epoch. An admission, published under the new epoch, names the old epoch's heads. A joiner cannot open those events, so for the joiner they are dangling soft edges, ignored as dangling parents are today. Nothing about F-16 changes: `after` carries ids, never content, and an id of an event you cannot open tells you nothing you could not count on the store node.

An entry's **epoch** still comes from the key that opened it (`CoordinationSession.sealedIn`), not from its position. Causal order makes position closer to time, but a member who has not yet ingested a grant keeps sealing under the old epoch. Its events are concurrent with the admission, not before it.

## 4. What it buys

- **Replay that is the order things happened**, up to concurrency. Two events with no path between them in either relation really were concurrent: neither publisher had seen the other's. The tie between them is broken by id, and the map can draw concurrency as concurrency.
- **A proposal's state at each step.** The graph can then carry each intent's state after each of its entries, `reduceIntentViews` over the causal prefix. That is a pure function of a set of events, so it is honest: the room's state as of that point in the replay. Today's "Now: Final" pill goes away.
- **An activity feed in lifecycle order** without the special-casing at `intents.nim:663`.
- **"What had they seen when they acted?"** An approval's causal ancestors are what its author's log held when it signed. The Provenance lens can show that, next to the inputs the signature commits to (the record).

## 5. Decisions for the operator

1. **`after` as an annotation outside identity (recommended) or as part of the id.** Putting it in the id would make every copy distinct and drop the convergence rules in §3.1. The price is everything in §2: re-announce must reuse stored copies, re-publishing creates duplicates, and the provenance record and audit see more events. The annotation keeps every invariant-guarding path byte-for-byte as it is.
2. **Sign `after` on author-bearing kinds, now or later.** Unsigned, any member can re-publish a copy with a different `after` and, by grinding its digest, have it chosen. That reorders a view, never state. The recommendation was to do it later as its own slice; it was built as C5 with a signature separate from the author's claim, not a second claim version (§7a).
3. **Which views move to `causalOrder`.** Recommendation: the room map and the activity feed. Flow and provenance get each entry's epoch from `sealedIn` (exo-dde.9), and their row order can stay canonical.

## 6. Slices

Each slice's acceptance becomes a test before the code.

| Slice | What | Accept |
|---|---|---|
| **C1** | `log.nim`: `Event.after`; the id unchanged; the log keeps the min-digest variant; `causalOrder` with cycle-safe soft edges | property tests: any arrival order and duplication of the same variant set gives the same `causalOrder`; every event is emitted; with no `after` anywhere, `causalOrder == canonicalOrder`; a planted forward edge is skipped, not looped |
| **C2** | `reduce` and every fold ignore `after` | a probe (append-only) proves invariant 4 is untouched: `reduce(events) == reduce(events with every after stripped or rewritten)`, and every signing-path byte equal |
| **C3** | `session.publish` stamps heads; re-publishing re-seals the stored copy; wire encode/decode | `session_test`: a new event names the log's heads; a re-announce carries the original `after`; an older client's decode ignores the field and computes the same id |
| **C4** | the room graph replays by `causalOrder`; each intent's state per step; the activity feed in causal order | `room_graph_test`: replay order follows causality in a two-member run; an intent's state at each step equals `reduceIntentViews` of the causal prefix; the map's "Now:" pill is gone |
| **C5** (built, §7a) | `after` signed on author-bearing kinds (a separate after-claim) | `after_signed_test`: a re-published author-signed copy with a forged `after` reorders and suppresses nothing |

## 7. As built

- `log.nim`: `Event.after`, `afterDigest` / `keep` (the copy kept per id), `causalOrder`, `Log.find`, `Log.heads`. `Log.ingest` replaces a held copy only with the one `keep` chooses.
- `session.nim`: `publish` re-seals the stored copy of a held event, else stamps `Log.heads()`; `encodeEvent` writes `after` only when non-empty, `decodeEvent` reads it.
- `room_graph.nim`: positions are causal; each intent carries `steps`, its state and approvals after each of its entries (the fold over the causal prefix, kept where they change). The fold's cost is quadratic in the log; G7 bounds it.
- `intents.nim` `reduceActivity`: sorts by causal position; `seq` stays canonical.
- `RoomMap.qml`: replays by causal position, shows each proposal's state at the replay point, and says "in the order members saw them" (until C5).

### 7a. C5, as built: the author signs `after` (exo-dde.15)

A first reading of decision 2 was to put `after` inside the author's signature over the event. That would make an event with a rewritten `after` a forgery the room drops, and the room map's spec (`derived-exo-dde` s3) holds that rewriting `after` never changes state. So the signature is separate:

- `afterSig` is the author's Ed25519 signature over `muster.event.after-claim.v1` (room, the event's id, its sorted `after`). Like `after`, it is outside the id and travels on the wire only when present.
- `publishAuthored` stamps the heads, signs the event as before (that signature still excludes `after`), then signs `after`.
- The log keeps up to 64 distinct copies of each event (`Log.allVariants`). The authentic view (`authenticEvents`, `roomEvents`) reads, of an author-bearing event's copies, the one whose `after` its author signed, choosing by digest among those. If none is signed, it keeps the event and drops only its ordering claim.
- So a member who re-publishes someone's message with a forged `after` reorders nothing and suppresses nothing (`after_signed_test`). Events that name no author keep an `after` that is any member's claim, as before.
- Bound: a member who floods 64 forged copies before the genuine one arrives fills the variant list; the genuine copy then loses its ordering claim (never the event). Raising the bound costs memory; the case is noted, not handled.

## 8. What could go wrong

- **A large `after`.** Concurrency is low in a room, and the cap is 8. A log of thousands of events adds about 1–3 ids per event on the wire, inside the sealed envelope.
- **A misleading order from a hostile member.** Bounded by §3's rule: views only, never state. Since C5 this holds only for sealed kinds (a proposal, a submit), whose `after` any member can claim, so the timeline still says "in the order members saw them".
- **Mixed clients.** An old client's events have no `after` and stay roots in `causalOrder`, so a room with old clients replays partly in id order. The map can mark events that carry no causal order.
