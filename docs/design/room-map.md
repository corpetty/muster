# The room map: a room's state and history as a graph (epic exo-dde)

**Status:** G0, G1, G3 and G4 landed 2026-10-11 (`coordination/room_graph.nim`, `coordinate_graph(room_topic)`, `ui/src/qml/RoomMap.qml`); G2 (spec `derived-exo-dde`, graded 3/3), G5 and the validation lenses landed since; G6 and G7 in part (§9). Mock: [`ui/prototype/room-map.html`](../../ui/prototype/room-map.html), a self-contained HTML/JS simulation on Logos.Theme's token values, like `desktop-v3.html`. It is not the app.
**Reads with:** [action-manifest.md](action-manifest.md) (the manifest, M4 provenance, M5 flow), [side-modules.md](side-modules.md) §4 (what may leave `muster_module`), [ui-modernization.md](ui-modernization.md) §9 (where Room details lives now).
**Paths:** short paths are under `module/src/`.

## 1. What is asked

A view that takes a room's log and draws the room: its members and epochs, its proposals and how each got where it is, the links between *you* and the room, what you disclosed, and where information left. It should be a graph you can move through, and it should look good enough that people want to open it.

## 2. What already exists

Almost every fact the map needs is already a fold over the log. The map adds no new truth. It joins folds that today render as separate lists.

| Fact on the map | Fold that already computes it | Lidl method |
|---|---|---|
| Log entries in canonical order, their parents (the hash-linked DAG) | `log/log.nim` `canonicalOrder`, `Event.parents` | `coordinate_proof` (raw), `coordinate_activity` |
| Each entry's class, author, guarantee, epoch, attestation grade | `coordination/intents.nim` `logProvenance` | `coordinate_provenance` |
| Who could see what, per entry, per observer class | `coordination/flow.nim` `reduceFlow`, `observerMatrix` | `coordinate_flow` |
| Each intent's state, threshold, approvals, declines, parts | `reduceIntentViews` | `coordinate_intents` |
| One intent's input lineage (inputs → signed bytes) | `attest.nim` `intentInputs` (invariant 10) | `coordinate_provenance(intent)` |
| Accounts disclosed into the room, and by whom | `coordination/accounts.nim` | `coordinate_intents` / room accounts |
| Members, epochs, admissions | `membership/<e>/admit/<who>` events; roster | `coordinate_members` |
| Which outside observers a room has introduced | `room_infra.introducedObservers` | `coordinate_flow` |
| What this instance can do about an intent | `coordination/readiness.nim` | `coordinate_readiness` |

So the work is a projection that composes these into nodes and edges, and a view that draws it well.

## 3. Where it lives: inside muster, not a separate module

The request says "module". A separate Logos module that receives the room log would hold decrypted room data in a second process. Side-modules §4 rules that out: the event plane carries no auth token, a Nim provider cannot see its caller, and Basecamp runs with the access policy off, so a module holding room plaintext serves it to every co-resident module. Splitting the kernel adds a copy of the plaintext and gains nothing.

So:

- **The projection is a fold in `muster_module`**: `coordination/room_graph.nim`, `reduceRoomGraph(events, driverFor, founders, viewer)`, served as one new lidl method `coordinate_graph(topic)`. It is a pure function of the authenticated log (`roomEvents`), so it obeys invariant 4 and inherits authorship (exo-f76) for free.
- **The view is QML in `muster_ui`**: `RoomMap.qml`, opened from Room details as a fourth tab beside People, Accounts and History, and from a card's "Who sees this?" as a filtered view.
- **The graph carries the content, all of it** (operator's decision, 2026-10-12; it first carried structure only). The map is local, read by the member's own client, and a map missing what was said, what was proposed and what was paid is not useful. So each entry carries its value parsed (message text, the effect, context, read values, signatures, chain references, payment reports, material, account details), each proposal its effect, summary and materialization hash, and each crossing the values that left and the transaction that sent them. What bounds it is invariant 7, not a content rule: the graph holds nothing this member's session did not decrypt, content included, which is what spec `derived-exo-dde` s1 grades. `coordinate_messages` already serves the same text to the same callers. One kind is the exception: an entry under `voice/` (`docs/design/voice-notes.md` §10) carries a voice note's metadata alone, `v`, `ts`, `durMs` and `digest`, never its half of the clip, since any caller can read the map. So no hosted method returns a note's audio from this member's view: the map strips `part`, and `coordinate_proof`, whose proof would carry every value whole, refuses a room whose view holds a part of a voice note (`voice-notes-present`) until the operator decides (voice-notes.md §10, §18). An entry under `voice/` that is no note's part leaves with a proof whole, so junk that copies a note's bytes carries them out when this member's view holds none of that note's parts (voice-notes.md §10, "What is left"). A client from before voice notes (0.3.4 or earlier) still carries the whole value (voice-notes.md §10, "What still leaks", item 6).

## 4. The data contract

```
coordinate_graph(topic: tstr) -> result<tstr, tstr>   ; JSON, below
```

```
{ "viewer":  "<member id>",          ; this instance's encryption identity
  "readFrom": 0,                     ; the first epoch this instance holds (F-16)
  "seqMax":  41,
  "epochs":  [ {"epoch":0,"from":0,"admitted":null}, {"epoch":1,"from":9,"admitted":"<id>"} ],
  "nodes": [
    {"id":"m:<id>",  "type":"member",   "epoch":0, "self":true},
    {"id":"i:<id>",  "type":"intent",   "seq":12, "family":"safe", "state":"final", "label":"Pay 1.5 ETH"},
    {"id":"a:<caip10>","type":"account","seq":4,  "discloser":"m:<id>"},
    {"id":"e:<cid>", "type":"entry",    "seq":12, "kind":"sig", "cls":"driver-contribution",
                     "account":"m:<id>", "epoch":1, "attestation":"committed", "guarantee":"…"},
    {"id":"o:chain-observer", "type":"observer"} ],
  "edges": [
    {"from":"e:<cid>","to":"e:<cid>",          "type":"parent"},             ; the hash link
    {"from":"m:<id>", "to":"e:<cid>",          "type":"authored"},
    {"from":"e:<cid>","to":"i:<id>",           "type":"input", "cls":"external-read"},
    {"from":"i:<id>", "to":"o:chain-observer", "type":"discloses", "seq":31,
                      "fields":["to","value","signers"], "declared":true},
    {"from":"m:<id>", "to":"a:<caip10>",       "type":"disclosed", "seq":4} ] }
```

Rules the fold keeps:

1. **Every node and edge carries the `seq` it appears at.** The view replays `reduce(log[0..k])` by filtering on `seq ≤ k`; it never computes state itself.
2. **`seq` is a display index only.** Canonical positions shift when an earlier-sorting event arrives (exo-ef1), so nodes are keyed by content id, never by index, and a late arrival re-flows the timeline without renaming anything.
3. **The viewer lens is a highlight, never extra knowledge.** `self` marks this instance's own member node. The fold adds nothing about another member that the log does not already state, and every member's map of the same log is the same graph apart from `viewer` and `readFrom` (invariant 9).
4. **Epochs before `readFrom` are one sealed node.** A member admitted at epoch 2 sees "before you joined: sealed" and nothing of its contents, because its client cannot open those envelopes (invariant 7, F-16). The fold cannot leak them because it never received them. As built, the fold does not know *how many* envelopes are sealed: the session drops what it cannot open, so the count the mock shows needs the session to keep one (a G4 question).
5. **Leaves are placed when information leaves**, exactly as `reduceFlow` places them: the driver's declared rows at submit/final, or at each part's settle for a parts intent (after exo-c7c). An undeclared driver produces an `undeclared` edge, drawn as such.
6. **Inputs entering the room are edges too.** An external read (a Safe nonce, a fiat quote, a chain read behind an account disclosure) is an edge from outside the boundary inward, so the map shows what the room took from the world as well as what it gave.

## 5. The view

The mock shows each of these. One picture, five lenses, one timeline.

### 5.1 The picture

- **The boundary is the centre of the composition.** The room is a large soft membrane. Inside it: members on an inner ring, accounts and shared material between them, proposals in the middle. Outside it: the observer classes at fixed bearings (store node above, RPC provider and chain observer to the right, a target module to the left).
- **Crossing the membrane is the event the map exists to show.** An edge that leaves is drawn in the primary orange with particles moving outward. An input that enters is drawn in info blue, dashed, moving inward. Everything inside is quiet.
- **The store node sees every envelope.** A faint strand bundle from the membrane to the store node thickens with each entry. Its label says what the code says: timing and topic, for every entry; it cannot open one (FS-9).
- **Epochs are rings of time, not space.** On the timeline they are bands; on the map, an admission is a pulse across the membrane and the joiner's node arriving.
- **Layout is deterministic.** Positions come from the log (bearing by member id, radius by role), never from a seeded force simulation, so the same log draws the same picture on every device and nodes do not jump while you scrub.

### 5.2 Lenses

| Lens | Shows | Answers |
|---|---|---|
| **Room** | everything at seq k | What is this room, and what state is it in? |
| **Me** | your member node, your keys and their binding, what you disclosed, what you signed, and which of those then left | What does this room know about me, and what did it pass on? |
| **Where it left** | only edges that cross the membrane, with each observer's field list (the observer matrix) | Who outside the room learned what, and when? |
| **Provenance** | for one selected intent: each input that reached its signed bytes, coloured by class, with its author and log position | How did this decision get in front of me? (invariant 10) |
| **Log** | the literal hash-linked DAG, entries left to right in canonical order, parent edges, epoch bands | What exactly is in the log? |

Switching lens animates nodes to their new positions.

### 5.3 Timeline

A strip under the map: one tick per log entry, coloured by kind, on epoch bands. Drag to replay, or press play. The state digest beside it changes as you scrub, which is the visible form of `state = reduce(log)`. Ticks for entries in sealed epochs are drawn as one hatched band.

### 5.4 Inspector

Selecting a node opens a side panel: what it is, who placed it, the guarantee text `logProvenance` already writes for that kind, its epoch, its content id, who could see it, and links to the card, the proof and the audit trail. Copy follows the card's voice: what the code enforces, never more.

## 6. What designing it found

- **exo-c7c (bug):** `reduceFlow` never places a parts intent's outside rows. A split settles through `intent/<id>/part/<part>/<step>` and writes no submit/final, so the payer, payee, amount and group linkage that the split's manifest declares to the chain observer (`drivers/split.nim:877-880`) never appear in `coordinate_flow`. "Who can see what" currently says a paid split left nothing. It also adds no store-node row for `context`, `read`, `attest`, `proposer`, `part`, `account/` or `frost/` entries, though the store node sees every envelope. The map depends on this fold, so this is slice G0.
- **The founders bug (fixed with G3).** The host computed a room's founders as the roster minus every admitted joiner, but compared the roster in `strutils.toHex` uppercase against admit events in lowercase. No joiner was ever subtracted, so every later joiner counted as a founder, and "Who sees this?" listed them as able to read entries from before they joined. `flow.foundersOf` now compares without case; `flow_test` §7 holds it.
- **Message authorship is signed, and the guarantee text lagged (fixed, exo-37e).** Since exo-f76 a message carries its author's signature and `roomEvents` drops a forgery; `logProvenance` said the author "is what the sender wrote, not a verified signature". It now says what the read path enforces, and the graph names a message's author with basis `author-signed`.
- **An approval is a key, not a member.** A driver-counted approval names the authorization key that signed. The graph hangs it from a `signer` node, and ties that key to a member only through a binding whose statement verifies (`attest.bindingLink`), so a member is never shown approving on the strength of a name on a key.
- **External reads are not on the flow view at all.** The map's inbound edges (§4 rule 6) are new on screen, though `logProvenance` already classes `read` entries.

## 7. Slices

Each slice's accept criteria become a test before the code (working agreement).

| Slice | What | Accept |
|---|---|---|
| **G0** ✓ | exo-c7c: `reduceFlow` places part settles and every envelope | `flow_test`: a settled split part yields the manifest's chain-observer rows at that part's seq; every entry yields a store-node row |
| **G1** ✓ | `coordination/room_graph.nim` `reduceRoomGraph` over the existing folds; no new truth | `room_graph_test`: order and duplication give the same graph (R-2/R-3); two members' graphs differ only in `viewer`/`readFrom`; a joiner's graph has no node from an earlier epoch |
| **G2** ✓ | spec `derived-exo-dde` (discuss-issue, catastrophic): s1 a joiner's map holds nothing it did not decrypt, content included; s2 the same log draws the same map, and fingerprints change exactly where an entry differs; s3 `after` never reaches state or a signing path | `probe_room_map_joiner_stepper` (20), `probe_room_map_same_log_stepper` (24), `probe_after_never_reaches_state_stepper` (21) over real sessions; graded 3/3 by `scripts/grade-specs.sh exo-dde`; each shown red by a mutation |
| **G3** ✓ | `coordinate_graph` in `muster.lidl`, regen, hosted in `muster_module.nim` | `room_graph_live_test`: over real sessions, a joiner's map (what its session decrypted) starts at its admission; what both hold maps the same; the host module compiles (`probe_return_marshalling_host`) |
| **G4** ✓ | `RoomMap.qml`: deterministic layout, membrane, observers, edges, inspector (QtQuick Shapes) | `scripts/card-self-test.sh`: the map loads offscreen and names the room's observers |
| **G5** ✓ | timeline scrubber + digest; lens switching with animation | offscreen: scrubbing to k shows exactly the nodes with `seq ≤ k` |
| **G6** ◐ | entry points: Room details › Map, a card's "Who sees this?" opens the Provenance lens on that intent | looked at on a display (Xvfb + xdotool recipe) in the C++ and Nim hosts |
| **G7** ◐ | scale: messages fold into one node per sender per epoch, past ~200 entries the DAG lens windows | a 2,000-entry room scrubs at 60 fps offscreen |

## 8. As built (2026-10-11)

- **The view** is `RoomMap.qml`, an overlay on the room, opened from ⋯ › Room map and from Privacy's "See it on the room map" (which opens "Where it left" on the proposal Privacy was showing). It reads only `graph`, `intents` and `members` and speaks through two signals, so it can move to its own module later. Leaving is drawn in the info blue the room already uses for what left (U-2, `MusterStyle.info`), not the mock's orange; members use their id colour and `Avatar`.
- **`coordinate_graph(room_topic)`**: an empty topic is the current room, so a later standalone module is not tied to the room `muster_ui` last opened.
- **Gallery fixtures** `room-map*.json` (Room, Me, Where it left, Provenance, Log, a joiner, replay), recorded from `scripts/split-self-test.sh` through the Recorder, which now also asks for the graph. They assert the store node, the RPC provider and the chain observer are drawn, the menu calls `loadGraph`, and replaying to rank k holds k + 1 entries.
- **An entry's epoch is the key that opened it.** `ConversationCrypto.openedEpoch` names the epoch whose MAC verified, `CoordinationSession.sealedIn` keeps it per event (log + keys, invariant 4), and the graph uses it. Before this, every entry's epoch was read off its canonical position, which is wrong for events without parents (§6, exo-9e3d).
- **A room-key approval** (`ed:<key>`, the split's) hangs from the member whose identity starts with that key.

## 9. What is not true yet

- **Replay order is what members saw** (exo-655, `docs/design/causal-parents.md`). Each event carries `after`, the heads its publisher had seen, and the map replays by `causalOrder`; each proposal's state is shown as of the replay point. Since C5 an author-signed entry's `after` is read only when its author signed it, so a member cannot reorder another's messages or reports on the map; a sealed entry's `after` (a proposal, a submit) is still any member's claim, so the timeline says "in the order members saw them". Events from clients before this change replay in content-id order among themselves.
- **G6 in the Nim host**: the contract check (`ui-nim` `checks.contract`) covers the new slot and property; the Nim host has not been run on a display.
- **G7, at scale.** `room_graph_scale_test` builds a 1,850-entry room's graph: `causalOrder` takes ~9 ms, and the graph adds almost nothing beyond the folds it joins. Those folds took ~5 s each there: `canonicalOrder` re-sorted its whole ready list at every step, quadratic when most events are roots, and `approvalGrades` calls it about three times per proposal. A min-heap gives the identical order in n log n (exo-53d) and the three folds now take ~1.4 s together, held under 4 s by the test. The UI polls `coordinate_intents` every second, so a room that size is still worth watching. Seen at 420 entries (2026-10-12): `scripts/map-scale-self-test.sh`, run under `scripts/ui-screenshot.sh record`, posts 420 lines in a real runner and waits for the recorder to write the whole map; the gallery fixtures `room-map-large` and `room-map-log-large` replay it. The timeline draws one tick per two entries there. The Log lens shows the 80 entries around the replay point, about 11 px apart, says which ones ("Entries 161–240 of 420"), shades that window on the timeline, and labels an entry only on hover or selection. A 240-entry window put entries 3.7 px apart under overlapping labels. The run also found that C5 had made every hosted read re-verify each message's `after` signature (and the author signature `roomEvents` had already cached): a warm read of a 420-message room took 92 ms, now 2.6 ms, with both verdicts cached on the session (`after_signed_test` §6). The map's JSON for 420 chat lines was 770 KB, two fifths of it the same facets and guarantee repeated on every entry; each is now sent once (`facetSets`, `texts`) and Room.qml expands them, so it is 453 KB (exo-dde.19). The view still fetches it every 2 s while the map is open; fetching only when the log changed is the next saving.
- **Fixed since:** flow and provenance read each entry's epoch from the key that opened it (exo-dde.9, `epoch_attribution_test`); the message guarantee text (exo-37e); a per-thread `eventId` memo (exact, tested) took ~20% off every fold.
- **The sealed count.** The session drops envelopes it cannot open, so the map says "sealed to you" without a number.

## 10. Validating a room: trust, crossings and fingerprints (exo-f2d, exo-737, exo-26a)

Three questions a member should be able to answer without reading code:

- **Which connections are commitments the code enforces, and which rest on someone's word?** Every entry carries **facets** and every edge a **credibility**, in the claims registry's vocabulary (`docs/design/action-manifest.md` §2):
  - **imperative**: the discretion to defect is removed structurally;
  - **motivational**: a named party could defect but has a reason not to;
  - **exposed**: the information reaches an unbound observer;
  - **not-applicable**: nothing is promised (a refused entry).
  Each facet names what it is about, the party and the mechanism. The mechanisms restate guarantees the code already enforces; `room_graph.facetsFor` is the one place they are written, and no facet adds a guarantee. A payment report is two facets: "who wrote it" is imperative (an author signature bound to the room), and "that it was paid" is motivational, the payer's word until the counterparty confirms from their own read. Every entry also says who could read it (imperative: that epoch's key) and that the store node saw it arrive (exposed). The **Trust** lens colours every connection by class and lists, grouped by party, what the room relies on. It counts; it never scores.
- **What left the room, to whom and when; what came in, how and when?** The graph's **crossings** list every boundary crossing, in causal order:
  - **out:** each field an outside observer learned, at the entry that sent it (the store node's metadata is one summary row);
  - **in:** each outside read, with its source and how it was recorded (invariant 10): a nonce, a rate, the chain's answer, a counterparty's confirmation; plus accounts and material members brought in;
  - **join:** each admission, from which epoch the joiner reads.
  The **Crossings** lens lists them with their class, up to the replay point. Selecting a row opens the entry that caused it.
- **Do I hold the same room as you?** The graph carries a **fingerprint** per epoch: a digest of the ids of the entries held from that epoch on. It is offered only from an epoch whose entries are held, so it depends on what is held, never on who looks. Two members who read the fingerprint from an epoch they both held aloud, and get the same value, hold the same entries from then on. In the recorded split, Alice and Bob both read `8132 aec2 06c6 a030…` from epoch 1. The panel also counts the entries the room **dropped** because their author signature failed (raw log minus the authenticated view). A member can paste another's fingerprint and the panel says whether it matches one held, and from which epoch.
- **One proposal at a time.** Privacy's "See where this proposal's information went" opens Crossings filtered to that proposal, with a chip back to the whole room; a proposal's panel says what it relies on, by party, before anyone approves it.
- **What is new since you looked.** The map remembers, per room and on this device only, how many entries it showed when it closed; new entries are marked and can be replayed on their own.

## 11. Open questions

1. **A UI-only module later?** The map could ship as its own `.lgx` calling `coordinate_graph`. It would be a second reader of room structure. Recommendation: start inside `muster_ui`, decide after G6.
2. **Export.** The map of a room is a picture someone may want to share. A shared picture of a room is a disclosure, so any export should say what it reveals (who is in the room, when they acted) the way the audit download does.
3. **The Learn walkthrough.** The map is the natural place for the six-step lifecycle legend to point. Whether `Walkthrough.qml` drives the map with a scripted log is for after G5.
