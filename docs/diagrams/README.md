# Diagram programme

**A plan, not a gallery.** This catalogues the diagrams Muster needs, what each must be true about, and where it gets its facts.

Two things already exist and the plan is built around both: five static figures in `docs/posts/figures/`, made for post 1, which set the visual vocabulary (§1); and `logos-co/assembly`'s **interactive basecamp stack preview**, which supplies an engine several of these diagrams should be built on rather than reinvented (§3).

Two audiences, and a diagram earns its place by serving at least one of them well:

- **[BUILD]** — the packaging and host work. Someone has to make the basecamp-hosted and standalone paths the same app, and reason about module boundaries, generated surfaces and per-instance state to do it. These diagrams are working documents for that person; they happen to be publishable.
- **[POST]** — the forum series. Name the parts of the stack, show where information leaks, and correlate the transaction pipeline to the infrastructure that actually runs each stage.

The bridge between them is the observation that **an architecture diagram of this system is already a privacy diagram** — every box is somebody who can see something. Where a diagram serves both, it is marked **[BOTH]**, and those are the highest-value entries in the catalogue.

---

## 1. Conventions

Inherited from the post-1 figures, which established them; restated here so the set stays coherent as it grows.

| | |
|---|---|
| **Format** | Hand-authored SVG. No build step, no diagram DSL, no external renderer |
| **Palette** | The prototype's tokens, so figures and app screenshots sit together (§1.1) |
| **Type** | Plain `<text>`; no font embedding. Anything rendering these substitutes a local sans — deliberate, and why nothing depends on a particular face |
| **Width** | 880px viewBox — a forum post's content width. Height varies |
| **A11y** | Every figure carries `<title>` and `<desc>`; `<desc>` states the argument in a sentence, so the figure survives being read aloud |
| **Raster** | A 2× PNG beside each SVG. Most forum software handles PNG more reliably |
| **Colour** | Never load-bearing alone. A ●/◑/○ mark, a label or a position carries the meaning; colour reinforces it |

### 1.1 Tokens

From `ui/prototype/coordination-prototype-v2.html`. The dark tokens are not decoration — **the ground turns dark exactly where the conversation boundary is crossed**, and that convention is already doing work in fig3. Keep it.

```
paper   #E4E6E0   surface #F7F8F5   ink     #1A1F1C   muted #656E66   rule #C6CBC3
signal  #4B33C4   signal-soft #EAE6FA
settled #1E6B52   settled-soft #DFEDE6
alarm   #A32D1E   alarm-soft   #F6E3DF
outside #23282A   outside-ink  #DCE2DE   outside-rule #3A4144   outside-accent #8FA3F5
```

Semantics as used so far, worth holding to: **signal** = the pre-transaction stages, the thing being argued about. **outside** = beyond the boundary; someone else's infrastructure. **settled** = closed by default architecture. **alarm** = a leak or a gap, used sparingly enough that it still registers.

### 1.2 Layout and naming

**Decided.** One directory, slug names. The `figN-` scheme is numbered against post 1 and would collide the moment post 2 has its own fig1.

```
docs/diagrams/
  README.md              this catalogue
  manifest.json          provenance, machine-readable (§2)
  substrate-*.html       interactive substrates — one file each (§3)
  arch-*.svg             deployment, packaging, module boundaries
  pipeline-*.svg         the seven stages and what leaks
  mech-*.svg             Muster's own guarantees
  series-*.svg           reusable series chrome
  *.png                  2× renders, beside their source
```

Cost of the move: five renames and a one-line update to §8 of `docs/posts/01-discovery-supporting-material.md`. Paid once, at the head of tranche 1, while the set is five figures rather than fifteen.

Figures exported from a substrate (§3.2) are named `<substrate>-<view>.svg` and are **generated artefacts** — committed for forum embedding, but edited at the substrate, never by hand.

Re-render after any edit:

```bash
nix shell nixpkgs#librsvg --command bash -c 'cd docs/diagrams && for f in *.svg; do rsvg-convert -z 2 -o "${f%.svg}.png" "$f"; done'
```

---

## 2. The drift problem, and the answer

**Decided.** Architecture diagrams rot silently, and this repo has an unusually low tolerance for that: the vision's honesty rules bind figures exactly as they bind prose, and ADR-012 already establishes the pattern for enforcing a documentation property in CI.

**ADR-012's insight applies directly.** CI cannot check that a claim is *true*; it can make a silently vanishing caveat impossible, because that is the failure mode honest documentation actually has. A diagram's version of that failure is subtler and worse: the figure keeps rendering, keeps looking authoritative, and quietly describes a topology that changed two phases ago.

So each figure carries a provenance block, and `manifest.json` makes it checkable:

```xml
<desc>One sentence stating the argument, for a screen reader.</desc>
<!-- provenance
     serves:   BUILD | POST | BOTH
     sources:  demo/muster-ui/metadata.json
               demo/muster-ui/flake.nix
     evidence: [measured] proving time, 2026-08-11, 13-core desktop
               [from source] module dependency set
               [illustrative] the conventional-stack column
     recheck:  P3 start (ADR-010 may remove the chat_module box)
-->
```

Two CI checks, mirroring ADR-012's split between what must resolve and what must merely be declared:

- **Fail** when a listed source path does not exist. A figure whose subject was deleted is a figure describing nothing — the same failure as a protection claim whose test was deleted.
- **Warn** when a listed source's content hash has changed since the figure was rendered. Most source changes do not invalidate a figure; the warning is a prompt to look, not a verdict.

And one rule that is the author's, not CI's, carried from §8 of the post-1 supporting material where it was stated informally and should now be structural: **every figure declares which of its content is measured, which is read from source, and which is illustrative.** Fig1's "to a directory / to an explorer / to a chat host" and fig4's "a person will wait this long" band are both illustrative, and both sit inside figures whose other content is measured. A reader cannot tell those apart by looking. The `evidence:` lines make the distinction recoverable, and where a figure mixes them heavily the distinction should be visible *in the figure*, not only in its provenance.

---

## 3. The interactive substrate

`logos-co/assembly`'s [basecamp stack preview](https://logos-co.github.io/assembly/static/basecamp-stack-preview.html) ([source](https://github.com/logos-co/assembly/blob/v5/quartz/static/basecamp-stack-preview.html)) is a better starting point than anything in this catalogue, and it should be reused — but the thing worth taking is the **engine**, not the picture.

### 3.1 What the engine actually is

Stripped to its idea:

> One static labelled substrate. A declarative list of named traversals over it. Everything not in the current traversal dims; the path lights up and animates; a caption changes with it.

Concretely — 880 lines, self-contained, no dependencies:

- A 960×600 SVG where every node group carries a `data-id`.
- A `VIEWS` array. Each view is `{id, label, accent, title, body, entry, paths, extras}`, where `paths` is an array of node-id chains.
- `setView()` clears highlights, sets `data-view` on the SVG (CSS dims everything without `.bc-hl`), highlights each id in each path, and **generates the flow arrows geometrically** from the nodes' own `rect` coordinates — routing the horizontal segment into the inter-band gap so it never crosses a label.
- Tabs built from `VIEWS`; autoplay rotates until the first click; a `dataset.initialized` guard survives Quartz's client-side re-renders.

**Adding a view is adding one object to an array.** No new geometry, no re-layout, no arrow-drawing by hand. That is what makes it worth adopting: the marginal cost of the *tenth* thing you want to show through a substrate is near zero, and this catalogue is full of diagrams that are the same substrate seen ten ways.

### 3.2 The move this unlocks

If the substrate is one SVG and the views are data, then **a static figure is just a frame of the interactive one** — apply a view's highlight classes, serialise, done.

That collapses a problem §1 otherwise leaves open. Interactive pages need `<script>`, and forum software routinely strips it (Discourse does). So the interactive version lives on a hosted page and the post embeds a static image — which normally means maintaining two artefacts that drift. Here it means one artefact and a render step:

```
substrate.svg + views.js  ──┬──►  hosted interactive page
                            └──►  frame export ──► pipeline-x-view-y.svg ──► .png
```

The SVG entries in the catalogue below therefore do **not** become obsolete. They become the export targets, and several of them stop being separate pieces of work.

### 3.3 What must change before Muster reuses it

**One correctness fix, and it is not optional.** The network layer reads `P2P · discovery · peering · mix`, and the messaging view is titled *"Encrypted chat over the mixnet"* with body text about traffic riding "out through the mix-routed P2P layer". By this project's own rules that is a shipped-status claim for something at status `raw` — a send-only testnet proof of concept, not on the published near-term roadmap. `00-vision.md` names this exact failure ("'Coming soon' is not a status and never appears in the walkthrough"), and post 1 already prints the honest version.

The fix is cheap because **the vocabulary already exists in the file**: `.bc-node-proposed` — dashed stroke, muted italic — is defined and used for the Monero module. Mix needs the same treatment, split out of the P2P bar as its own dashed element rather than listed as a shipped property of it. Worth raising upstream regardless of whether Muster forks it; the diagram is otherwise careful, which is what makes this row stand out.

**Then, in rough order of effort:**

| | Change | Notes |
|---|---|---|
| Facts | Add `muster-ui` (UI plugin), `muster_module`, and for the demo build `lez_core` | The LEZ node is already there and close enough to reuse |
| Facts | Nothing represents `capability_module`, the `ui-host` process split, or the Waku node embedded in delivery | Correct as-is — this is a **layer** diagram, not a **process** diagram. Those facts belong to `arch-instance-topology`. Keep the two from blurring |
| Style | Re-skin to the prototype tokens (§1.1) | Cheap: everything is already on `--bc-*` custom properties. Body font, page chrome and the red/green/blue/amber accents all go |
| Style | No equivalent of the dark-ground-means-outside-the-boundary convention | Needs adding if the pipeline views are to sit beside fig3 |
| A11y | Three infinite animations (`bc-blink`, `bc-flow-dash`, autoplay every 4.5s) with no `prefers-reduced-motion` | U-10 obligation. Autoplay that reflows the caption on a timer also needs a pause control (WCAG 2.2.2) |
| A11y | `role="img"` + one `aria-label` on the whole SVG; caption updates are not announced; `role="tab"` without `tablist`/`tabpanel` wiring or arrow-key navigation | A screen reader currently gets the overview and nothing else, whichever view is selected. `aria-live` on the caption is most of the fix |
| Reuse | Single file with inline `<style>` and `<script>` | Keep it. It matches the no-build-step convention and `coordination-prototype-v2.html` already works this way |

### 3.4 Which catalogue entries become views rather than figures

Three substrates absorb roughly a third of the catalogue:

- **`arch-three-hosts`** is very nearly the existing diagram already — Basecamp / Standalone / Headless are its three entry zones. Muster's version specialises it: same substrate, views for *default basecamp user*, *standalone Muster*, *`logoscore` headless*, and *demo build vs spec build*. This is the highest-leverage reuse in the whole plan and it is mostly deletion and relabelling.
- **`pipeline-stack-correlation`**, the keystone, gets substantially better as a traversal than as a table. The supporting material insists the pipeline "has to be retold per use case, which is exactly what I intend to do in this series" — and a per-use-case retelling over one substrate is precisely what `VIEWS` is. Views: *send a friend £20*, *DEX trade*, *hire someone*, *NFT purchase*. Same seven stages, visibly different paths, visibly different observers.
- **`pipeline-observer-panel`** inverts the selector: the views become *what the store node sees*, *what the zone sees*, *what a chain reader sees*, *what a compelled operator sees*. One journey, four traversals, and the dimming does the argument's work for it — what stays lit is exactly what that observer learns.

---

## 4. Catalogue

Thirty entries in four families. Each names what it shows, who it serves, what it derives from, and what it must not claim. Entries marked **▣** are views of a shared interactive substrate (§3.4) rather than standalone figures.

### Family A — Deployment, packaging and module boundaries

The set that makes the basecamp/standalone work tractable. Almost all of it is [BUILD]-first, but A1, A4 and A5 turn out to be publishable as-is, because "which process is this running in and who wrote it" is a question a privacy-minded reader also has.

| Id | Shows | Serves | Derived from | Must not claim |
|---|---|---|---|---|
| **arch-three-hosts** ▣ | One module set, three hosts: `logoscore` headless, standalone app, basecamp-hosted. What is identical (the module set, the contract surface, per-instance state) and what genuinely differs (who owns the event loop, who supplies the QML host, how the UI plugin is discovered) | **BOTH** | `02-implementation-plan.md` §stack decisions; chat-ui README "How to Run"; `metadata.json` | That basecamp-hosted is *shipping* for Muster. Today it is the chat-ui fork's path and Muster's target |
| **arch-instance-topology** | One running standalone instance, drawn honestly: the core process, `capability_module`, `chat_module` (embedding libchat), `delivery_module` (embedding a Waku node, joined to `logos.test`), `lez_core` (embedding wallet-ffi, pointed at the LEZ testnet sequencer), the isolated `ui-host` process, and the QtRO socket between backend and QML replica | **BOTH** | chat-ui README; `demo/muster-ui/metadata.json`; `demo/CLAUDE.md` | That anything here is local-only. **Two live remote dependencies** cross the process boundary and the figure should draw them crossing it |
| **arch-module-graph** | The `.lgx` dependency graph: declared `dependencies`, the `dependency_overrides` indirection (delivery's LIDL sourced *through* chat_module), and which edges are build-pinned versus runtime-resolved | BUILD | `demo/muster-ui/metadata.json`; `demo/muster-ui/flake.nix` inputs | That the graph is stable. `flake.follows` chains make several of these edges a version-lockstep decision, not an architectural one |
| **arch-demo-vs-spec** | The two builds side by side at the same scale: `demo/` (forked chat-ui + composed upstream modules, no log, no signing paths of our own) against specified Muster (`muster-module.lgx` Nim/LIDL core + `muster-ui.lgx`). Same host, same sockets, different insides | **BOTH** | `demo/README.md` invariant table; `02-implementation-plan.md` §repository layout | That the demo is an early version of the spec build. It is a **deliberate departure**, and the figure's caption has to say so or it will be screenshotted out of context |
| **arch-contract-seam** | What is generated and what is hand-written, on both sides. `muster.lidl` → `lidl_c.h` JSON bridge → Nim codegen → generated surface; `metadata.json#codegen` → `mkLogosQmlModule` → plugin entry + QtRO glue. The hand-written region is small and clearly bounded | **BOTH** | `CLAUDE.md` §pattern sources; `02-implementation-plan.md` ADR-008; `metadata.json#codegen` | That the Nim backend exists. It is P0's spike and the plan carries an explicit fallback |
| **arch-instance-state** | Where a peer's state lives: `--user-dir` → session dir → `module_data/<module>`, the wallet inside the chat instance directory, the two log writers sharing it. Why two peers cannot share a directory | BUILD | chat-ui README §multiple instances; `demo/CLAUDE.md` | — |
| **arch-build-distribution** | Flake inputs → `mkExternalLib` / `mkLogosQmlModule` → `.lgx` → `lgpm install` → host resolves and loads. Where the nix pin set actually bites | BUILD | `demo/muster-ui/flake.nix`; `02-implementation-plan.md` §stack decisions | — |
| **arch-capability-policy** | What a module may reach, and the plugin story on top of it: subprocess isolation, capability-scoped inter-module calls, and the F-12/F-13/FS-5 rule that plugins emit typed blocks and never sign, hold keys, or touch the network | **BOTH** | `CLAUDE.md` invariant 3; `02-implementation-plan.md` ADR-007, P5 | That third-party isolation is built. ADR-007 is documented-now, built-post-v1 |

### Family B — The pipeline and what leaks

The series' spine. Five exist; **pipeline-stack-correlation** is the significant gap and the one the whole catalogue is arranged around.

| Id | Shows | Serves | Derived from | Must not claim |
|---|---|---|---|---|
| **pipeline-seven-stages** | *(exists as fig1)* Seven stages, their leaks, the four before a transaction exists, the three the chain is in, the one the argument concentrates on | POST | PriFi competitor matrix cross-check | Conventional-stack examples are illustrative |
| **pipeline-stack-correlation** ▣ | **The keystone.** Each of the seven stages against the concrete infrastructure that runs it — three columns: *what runs this stage conventionally and who operates it* (platform search, explorer + surveillance firm, chat host + quote infra, web frontend + wallet RPC, public mempool, ledger + indexers, identifiable producers) / *what runs it here* (nothing — out-of-band address; nothing at all; the encrypted room over `chat_module`+`delivery_module`; the local native client; the zone sequencer; the zone's shielded transfer; the zone's sequencer set) / *who still sees, and what.* This is the diagram the user asked for by name and the one that makes the architecture and privacy readings the same reading | **BOTH** | `GAPS.md`; supporting material §1–2; `arch-instance-topology` for the box names | The two "not assessed" cells (Ordering, Enforcement) stay unassessed here too. A figure is exactly where an unscored cell gets quietly filled in |
| **pipeline-self-assessment** | *(exists as fig5)* Muster ●/◑/○ on its own matrix, two cells unassessed | POST | Supporting material §2 | — |
| **pipeline-observer-panel** ▣ | Extends fig3 from discovery to the **whole journey**: a column per observer (store node, the zone/sequencer, a chain reader, the peer, a compelled operator), a row per journey event, each cell what that observer learns. The honest answer includes several rows where the store node learns something | **BOTH** | `GAPS.md` §1–4; `WALKTHROUGH.md`; FS-9 | That any column is empty. Every observer learns *something* — a blank cell should mean "nothing", verified, not "not investigated" |
| **pipeline-three-leaks** | Chosen by you / chosen by the stack for you / inherited by everyone. Named in the supporting material as "the most reusable idea in the post" and currently prose only. One example per class, drawn from this build: a published address, one-topic-per-conversation subscription shape, a two-user anonymity set | POST | Supporting material §T5, §11 | — |
| **pipeline-four-rails** | private→private, public→private, private→public, public→public, against what each discloses (amount / payer / payee) and what it costs in time. The floor drawn across all four: **nothing hides that a transfer happened, or when** | **BOTH** | `demo/README.md` §four rails; `Assets.h`; `ChatBackendAssets.cpp` | Timings are measured on one machine; §5's "do not state as typical" applies |
| **pipeline-findable-unlinkable** | The fork: shielded receiving keys against the on-chain label system. Same stack, two discovery models, honest costs on both sides | POST | Supporting material §4; `lez_core` `add_label`/`resolve_label` | The label path is **not wired into Muster**. The figure must show it as available-in-the-stack, not as a feature |
| **pipeline-negotiation-comparison** | The strongest comparison in the build after the label fork: hosted multisig coordination (operator, and often anyone with the URL, sees proposal + signer set + who has signed + timing, all pre-chain) against the same stage inside the encrypted room with no coordination service in it | **BOTH** | `GAPS.md` §3b | Must carry the counterweight in the same frame: **the zone does not enforce the threshold.** Room-enforced, not chain-enforced |
| **pipeline-cost-of-privacy** | *(exists as fig4)* Proving time against human-interaction thresholds | POST | §5 measurements | The attention band is a rule of thumb, not measured here |
| **pipeline-journey-timeline** | A swimlane over real time for one complete journey: address exchange (seconds), proposal and approvals (seconds), proving (~7 minutes), sync and settle (variable, and *stale on first read*). Makes "not an interaction you wait on, a job you start" structural rather than asserted, and shows the settle-poll that `settleAfterTransfer` exists for | **BOTH** | §5; `demo/CLAUDE.md` on `settleAfterTransfer` | Same "do not state as typical" caveat |
| **pipeline-settlement-bug** | The account-id derivation drawn: `id = sha256(prefix ‖ npk ‖ vpk ‖ identifier)`; the recipient publishes the key node, the sender picks the identifier, so every payment mints a fresh account found only by scanning. What that buys, what it costs, and **the retraction of our own report of it as a bug** | POST | `demo/poc/BUG-private-transfer-recipient-identifier.md` §6; `GAPS.md` §4b | The slug is deliberately unchanged. Redrawn 2026-08-13 — an earlier version drew this as a settlement bug in the zone, and renaming the file would hide that the figure itself was corrected |
| **pipeline-discovery-comparison** | *(exists as fig2)* Introduction with a directory against without — who learns the edge | POST | §3 | — |
| **pipeline-relay-sees** | *(exists as fig3)* Content against metadata — what E2EE covers and what it does not | POST | FS-9; §3(b) | — |

### Family C — Muster's own mechanics

The guarantees, drawn. These serve later posts in the series and double as the reference for anyone implementing the phase. Most describe the **specified** client rather than the demo, and every one of them must say so on its face — this is where the catalogue is most at risk of publishing a diagram of something that does not exist yet.

| Id | Shows | Serves | Derived from | Must not claim |
|---|---|---|---|---|
| **mech-intent-lifecycle** | `draft → proposed → collecting → executable → submitted → settling → final`, with the vision's four teaching questions hanging off each stage. The curriculum spine, and the thing the walkthrough UI is a rendering of | **BOTH** | `00-vision.md` §lifecycle; F-3 | The demo has a subset (propose / approve / pay). Label which stages exist where |
| **mech-effect-materialization** | F-4/FS-6: what the user reviews (the effect, semantic), what gets signed (the materialization, bytes), the client re-deriving the second from the first, and refusing on mismatch. The contrast with blind signing is the whole point | **BOTH** | `CLAUDE.md` invariant 1; F-4, FS-6 | **Specified and unbuilt.** `GAPS.md` scores Contracting ◑ precisely because of this. A figure showing the check without showing its status would be the exact overclaim the project exists to avoid |
| **mech-signing-payload** | F-5 as a drawn record: environment, account, slot, expiry, `profile`, `schema-id`, effect value root. Why the signature is worthless anywhere else, and what each field defeats | POST | `CLAUDE.md` invariants 2 and 5b; ADR-009 | Specified. The demo builds no signing payloads at all |
| **mech-reduce-log** | State = reduce(log): append, ingest-verify, causal order with deterministic tiebreak, idempotent reducers, convergence under reorder and duplication. Worth drawing the adversarial-order property test as part of the figure | BUILD | `CLAUDE.md` invariant 4; R-2, R-3; P0 accept | The demo has **no log** — it folds `get_messages`. Same shape, different substrate, and the difference is what "nothing you could replay to prove what was agreed" means |
| **mech-membership-epochs** | F-16: epoch re-key on add and on remove, and precisely what a new member cannot read. The UI seam depends on this being real | **BOTH** | `CLAUDE.md` invariant 7; ADR-002 | ADR-010 is open — whether these epochs are ours or `chat_module`'s is undecided, and the demo "neither verifies nor claims" MLS re-keying |
| **mech-driver-seam** | Invariant 6 drawn: the core never interprets contribution bytes. Rounds, serialization domain, membership model and finality are driver-described. Stub / Safe / FROST against one interface, with the conformance suite as the gate | BUILD | `CLAUDE.md` invariant 6; F-6, F-7; P1–P2, P6 | — |
| **mech-two-identities** | ADR-010's blocking issue: an Ed25519/Curve25519 chat identity and a secp256k1 settlement key, holding the *same principle* on *different curves*, with no authenticated binding between them — and F-9 needing exactly that binding to derive per-member role. A live open decision, which makes it a better figure than a settled one | **BOTH** | ADR-010; `GAPS.md` §3 "nothing binds the chat identity to the zone account" | This is **unresolved**. The figure's value is that it draws a problem; do not draw a fix |
| **mech-plugin-blocks** | F-12/F-13: a plugin's manifest, its declared capabilities, content-hash verification at load, and the single narrow thing it may do — emit typed blocks. No canvas, no keys, no network | BUILD | `CLAUDE.md` invariant 3; P5 | Not built. The lying-plugin test is P5's accept criterion, not a current property |

### Family D — Series chrome

Cheap, and the thing that makes a multi-post series read as one argument rather than five posts.

| Id | Shows | Serves | Notes |
|---|---|---|---|
| **series-locator** | The seven-stage bar, one stage lit, everything else muted. One variant per post, ~880×80. Drops in at the top of each instalment so a reader always knows where in the pipeline they are | POST | Seven variants from one source. The cheapest coherence available |
| **series-map** | Which post covers which stage, which figures belong to which post, and which stages are not yet written. Editorial, published once, updated per instalment | POST | Also functions as the series' own honesty surface: the unwritten stages are visible rather than implied |

---

## 5. Sequencing

Ordered by what unblocks the most, not by family. Adopting the substrate engine (§3) reshapes this: tranche 0 is new, and the packaging set gets cheaper because much of it becomes views.

**Tranche 0 — foundations (small, do first).**

1. The §1.2 consolidation: five renames, one line in `01-discovery-supporting-material.md` §8.
2. `manifest.json` and the two CI checks from §2.
3. Fork the substrate engine, re-skinned to the prototype tokens, **with the mix correctness fix and the reduced-motion/`aria-live` fixes applied** (§3.3). Raise the mix row upstream at the same time.
4. The frame-export step (§3.2), so static figures are generated rather than drawn twice.

None of this produces a publishable figure. All of it makes every later tranche cheaper, and item 3 is the one with a correctness deadline attached — the current file states a `raw`-status capability as shipped, and anything forked before that is fixed inherits the overclaim.

**Tranche 1 — the bridge.** `arch-instance-topology` (static SVG), then `arch-three-hosts` and `pipeline-stack-correlation` as substrate views. The topology figure comes first because it is where the box names are established; the keystone draws from it and must not invent a component.

**Tranche 2 — the packaging set.** `arch-demo-vs-spec` (a view on the three-hosts substrate), `arch-contract-seam`, `arch-module-graph`, `arch-instance-state`. Working documents for the basecamp/standalone work; drawing them will surface open questions about the split before someone hits them in code.

**Tranche 3 — post 2 and 3 material.** `pipeline-observer-panel` (substrate views), `pipeline-negotiation-comparison`, `pipeline-four-rails`, `pipeline-three-leaks`, `series-locator`. Driven by which post is next; the locator strip is a half-hour and improves every instalment after it.

**Tranche 4 — settlement post.** `pipeline-journey-timeline`, `pipeline-settlement-bug`, `pipeline-findable-unlinkable`.

**Tranche 5 — deferred to their phase.** The Family C mechanics figures, each drawn when its phase makes it real: `mech-reduce-log` and `mech-signing-payload` at P0, `mech-driver-seam` at P1–P2, `mech-membership-epochs` and `mech-two-identities` at P3 (ADR-010's resolution changes what they show), `mech-effect-materialization` at P4, `mech-plugin-blocks` at P5. Two exceptions publishable now: `mech-intent-lifecycle`, because it is specified and stable, and `mech-two-identities`, because its value is drawing an unsolved problem.

---

## 6. Open questions

1. ~~How much of Family C should be drawn before its phase ships?~~ **Decided (§8, tranche 5):** draw the full set, with a status strip carrying the closed vocabulary, the requirement ids, the phase, and what exists today — placed above everything it describes so a screenshot cannot lose it.
2. **Does `pipeline-stack-correlation` subsume fig1**, or sit beside it? It is a superset of fig1's content plus the infrastructure column. Beside, probably — fig1 is the thesis and this is the evidence — but they should not both open a post.
3. **Should demo figures and spec figures be distinguishable at a glance** — a different ground, a corner mark — given the two builds coexist and one deliberately violates the other's invariants? `substrate-stack.html` answers it one way: a dashed "specified, not built" treatment applied *per node* rather than per figure, so one diagram carries both builds. Whether that generalises past this substrate is untested.
4. ~~Where do the interactive versions get hosted?~~ **Decided:** GitHub Pages on this repo, serving `docs/diagrams/` and nothing else. The substrates stay in-repo because they are Muster-specific and both the frame export and the manifest already operate on those files. A post embeds the exported frame and links out to the live view.

---

## 7. Decisions taken

| | Decision | Where |
|---|---|---|
| 2026-08-12 | Consolidate to `docs/diagrams/` with slug names; `figN-` retired | §1.2 |
| 2026-08-12 | Provenance block per figure + `manifest.json`, two pre-commit checks (fail on missing source, warn on changed source) | §2 |
| 2026-08-12 | Reuse the assembly substrate engine; static figures become exported frames rather than separately authored | §3 |
| 2026-08-13 | **Serve `docs/diagrams/` on GitHub Pages**, generated index and all — but only that path. The specification documents are already public in the repo; rendering them as a website is a separate decision | §8 |
| 2026-08-12 | **Draw specified-but-unbuilt guarantees, with the status above the content.** A strip carrying the closed vocabulary, the requirement ids, the phase and what exists today. Resolves §6 Q1 | §8 |
| 2026-08-12 | **Fork rather than upstream.** Muster is an app leveraging the stack, not the stack itself, so its substrate is its own artefact and diverges freely. The mix and a11y corrections live in the fork; passing them upstream is a courtesy, not a dependency | §3.3 |

## 8. Built so far

**The catalogue is built.** All five tranches are complete.

**Tranche 0 — foundations.**

| | |
|---|---|
| `substrate-stack.html` | The forked engine, re-skinned, six views. Mix and `muster-module` both shown as not shipped; a dark *beyond your device* band naming the observers |
| `manifest.json` | Provenance per figure, source hashes stamped |
| `tools/check-manifest.py` | `--update` re-stamps hashes, `--stamp` writes provenance blocks into the SVGs. All four failure modes verified to fire |
| `tools/export-frames.mjs` | Frames out of a substrate, no dependencies, idempotent |
| `tools/render-png.sh` | 2× PNGs, borrowing librsvg from nix when it is not local |
| `.pre-commit-config.yaml` | The `diagram-manifest` hook |

The five post-1 figures moved and were renamed; `01-discovery-supporting-material.md` §8 points at the new names.

**Tranche 1 — the bridge.**

| | |
|---|---|
| `arch-instance-topology.svg` | The **process** diagram, as distinct from the layer diagram: two processes, the QtRO seam with `ChatBackend` on the source side, per-instance state, and the two live remote dependencies. Establishes the box names |
| `substrate-pipeline.html` | **The keystone.** Seven stages × (conventionally, and who runs it / what runs it here / who still sees). Six views, including per-use-case retellings and one that marks the two stages left unassessed |

`arch-three-hosts` from the catalogue is **already covered** by `substrate-stack.html`'s basecamp / standalone / headless views and does not need a separate figure.

**Tranche 2 — the packaging set.**

| | |
|---|---|
| `arch-contract-seam.svg` | The two codegen paths and the small hand-written region each ends in, with the two rules `lidl_c.h` states outright and ADR-008's fallback. The Nim backend is drawn as not existing, because it does not |
| `arch-module-graph.svg` | What `metadata.json` declares against what `flake.nix` actually pins. Two of four inputs are not decisions — they follow the anchor; one names no release at all |
| `substrate-stack.html` → `spec-build` view | `arch-demo-vs-spec`, as a toggle rather than a side-by-side. Nothing moves between the two views except the app-backend layer, which is the point |

`arch-instance-state` is **struck** — `--user-dir`, `module_data/<module>/` and the wallet derivation are already in `arch-instance-topology`'s ON DISK column. The one fact it would have added and that appears nowhere: `chat_ui` and `chat_module` share the chat module's log directory, because the platform assigns a view module none of its own.

**Tranche 3 — post 2/3 material.**

| | |
|---|---|
| `pipeline-three-leaks.svg` | Chosen by you / chosen for you by the stack / chosen by nobody, each with a worked example from this build, its fix, and the obligation it puts on whoever describes it |
| `pipeline-four-rails.svg` | What each of the four transfer directions discloses and costs, over the floor that holds on all of them — plus the one place the honesty rule is enforced by code rather than by remembering it |
| `pipeline-negotiation-comparison.svg` | A hosted transaction service against the room, with the room-not-chain threshold limit in the same frame and the live trade it forces |
| `tools/make-locator.py` → 7 strips | The per-post "you are here" bar. Generated, because seven near-identical files that must agree is exactly what a script is for |
| `substrate-pipeline.html` → 3 views | `pipeline-observer-panel`, folded in. Selecting by *observer* rather than by stage — store node / the zone / nobody |

`pipeline-observer-panel` is **struck as a separate figure**: its axis is already the keystone's right-hand column, and three views get the per-observer reading for the cost of three objects in an array. The `obs-nobody` view carries the distinction worth keeping — negotiation is blank because it is closed, diligence is blank because the stage does not happen, and those are not the same thing.

Sixteen exported frames across the two substrates plus seven locator strips, each with a 2× PNG. Everything generated: edit the substrate or the generator, never the output.

**Tranche 4 — the settlement post.**

| | |
|---|---|
| `pipeline-journey-timeline.svg` | Every step of one payment on a log axis, against the thresholds where an interaction stops being one — with the 20-second sync-client timeout drawn through the middle, which is why a call that had sat in the tree for a day had never once succeeded |
| `pipeline-settlement-bug.svg` | The key node the recipient publishes, the identifier the sender picks, and the fresh account every payment therefore mints. Plus the trade that buys — no reusable identifier, and no balance you can look up — and the retraction of our own report of it as a bug, including why two independent measurements agreed and were both wrong |
| `pipeline-findable-unlinkable.svg` | The fork the stack offers, with **which side is actually wired in marked on the column itself** — the earlier prose draft implied a UI that does not exist |

**Tranche 5 — the mechanics, with a status treatment.**

Open question 1 is **decided**: draw the full set now, and put the status where a screenshot cannot lose it. Every Family C figure carries a strip immediately under its subtitle — a pill from the closed vocabulary, the requirement ids, the phase that builds it, and *what exists today instead*. It is the third line of the figure, above everything it describes.

| | Status |
|---|---|
| `mech-intent-lifecycle.svg` | **specified · part built** — F-3 · P1. The four states the demo reaches are marked on the states themselves |
| `mech-effect-materialization.svg` | **specified · not built** — F-4, FS-6 · P4 |
| `mech-signing-payload.svg` | **specified · not built** — F-5, FS-3 · P1 |
| `mech-reduce-log.svg` | **specified · not built** — F-1, F-2, R-2, R-3 · P0 |
| `mech-membership-epochs.svg` | **specified · not built** — F-16, U-6 · P3, entangled with ADR-010 |
| `mech-driver-seam.svg` | **specified · not built** — F-6, F-7, F-8, S-1 · P1–P2 |
| `mech-two-identities.svg` | **contested · unresolved** — F-14, F-9 · ADR-010, before P3 |
| `mech-plugin-blocks.svg` | **specified · not built** — F-12, F-13, FS-5 · P5 |

Written against `01-furps.md` directly rather than from the summaries, so every id and every quoted property is the normative text. `mech-two-identities` is the one to keep: F-14 is marked *Contested* in the requirements themselves, so the figure draws an acknowledged open decision and lists the three ways out without picking one.

**Published.** `docs/diagrams/` is served at **<https://corpetty.github.io/muster/>** by `.github/workflows/pages.yml`, which uploads the directory as it stands — no build step, because the substrates are self-contained and the figures are plain SVG. `index.html` is generated from `manifest.json` by `tools/make-index.py`, so a figure with no manifest entry cannot reach the site, and the workflow fails if the committed index is stale.

The artifact path is deliberately `docs/diagrams`, not `docs`. The specification documents are already public in the repository; rendering them as a website is a different decision, and a one-word widening of that path would make it without anyone choosing to.

**A third silent-failure class, now automated.** Text overflowing the canvas happened in three figures running — it renders, it looks fine in the source, and it is only wrong in the raster. `check-manifest.py` now estimates text width and warns. It is a heuristic (one advance-width factor per family) that catches a line 20% too long and will not catch one 2% too long, and it skips exported frames, whose font-size and anchor come from a stylesheet it cannot read.

**Two bugs fixed in the inherited engine**, both silent-failure shaped and worth knowing about: marker fills are unreachable by descendant selectors, so every arrowhead rendered grey; and a bare single-class text modifier (`.bc-flag`) loses on specificity to `.bc-node text`, so gap flags rendered bold-and-black instead of bold-and-red — the colour was the only thing marking a gap. Both are recorded in `tools/CLAUDE.md`.
