# Muster as the rails for the Logos world

> **Draft for Jarrad's review.** It is built on Jarrad Hope's "Logos as a Virtual World" Notion
> pages (2026-10-19 to 10-23) and the anvil-advisor bundle, whose sources are Logos Library books.
> This file paraphrases that material and quotes none of the books. Tracked as epic exo-267.

## The thesis in one paragraph

Jarrad's material keeps arriving at one sentence: *player law fills every vacuum, and the operator's
only choice is rails or improvisation.* EverQuest's raiders built DKP on websites the game could not
see. EVE's history only became history once the killmail existed. Logos's circles will build savings
and credit law whether we provide for it or not. Muster already is a large part of those rails. A Muster
room is a first-class group object. Its log is the group's ledger, readable by its members. Its
signature-audit file and log proof are attributed, automatic, factual receipts, which is the
killmail's three properties exactly. Its boundary gives Jarrad's "Logos delta" for free: *witness
by default, publish by consent.* What Muster does not have yet is the part of the story machine
past the room's wall: a deed that can leave the room by consent, a feed for it to land on, and the
group machinery (charter, roles, succession, federation) that turns a room into an org.

## What the material asks for, compressed

- **The story machine (seven stages).** Scarcity → orgs → collisions → irreversible outcomes →
  **witness → chronicle → commemoration**. Crypto already runs stages 1–4 hot. Stages 5–7 are empty
  ground, and they are application-layer work, which is where Basecamp (and Muster) live.
- **Org machinery (System 13), eight families.** A charter as a public, recorded act. Ranks and
  permissions: granular, default-deny, renamed by the players. An org ledger the members can read.
  Treasury, with destructive acts needing several keys and a delay. Succession. An *open betrayal
  surface* (the system secures process, never intent). Nested scale (about 5, then 15–50, a soft
  ceiling near 150, federation above). Org reputation and declared diplomacy, never enforced.
- **Circles: a species, not a type.** One generic org primitive. The circle ships as a charter
  template, not a type field. Two new primitives come out of BRAC and ROSCAs: *commitment thresholds*
  (a capability unlocks once the group has accumulated something legible) and *mutual stake*.
  Jarrad's own lint rule: if a feature checks "is this a Circle?" rather than "has this org met
  threshold T?", the design has drifted.
- **Deeds, not scores.** The system records attributed facts and people form the judgments.
  Deeds must bind to a persistent name, or they bind nothing (the alt problem). Pseudonymity has to
  serve as armor against the villain and as an anchor for deeds, both at once.
- **The law partition (P3).** Code enforces physics, not morality. The gap between coded law and
  social law gets written down before the first heist: what is coded-impossible, what is legal
  crime, and what is sanctioned.
- **The consent gradient (P4).** Bands run from digital to real stakes: a pseudonymous interior, a
  midband, an outer band where everything is at stake. Each border must be legible, a *city gate*.
  The UI page says it outright: the signing prompt is the safety toggle, tiered by band.
- **Asteroids (P5).** A privacy chain erases geography inside the protocol on purpose. So the
  located scarcity has to be placed: recurring, contested treasury rounds (the Curve-gauge pattern),
  scarce recognized stewardships, and zone standing. That is PvP among orgs in the midband, with
  PvE against the villain in the outer band.
- **The funnel and the quest web.** CURIOUS → TOURIST → RESIDENT. A resident has an org, a home,
  and recurring ties, never a count of hours. The first session's corridor has three acts: a solo
  win, an honest trade with a real counterparty, and a shared load that nobody can finish alone.
  The help edge runs from every node. Welcomers are paid in recorded standing, and *the helped party
  confirms it, never a headcount.*

## Where Muster is already right, by invariant

These are not loose analogies. Each one is a guarantee the code enforces today.

| World doctrine | Muster today | Where it lives |
|---|---|---|
| The org ledger: everything logged, readable by the org | State = reduce(log); every entry is authored, hash-linked and epoch-sealed; the room's history, provenance and map are folds over it | inv 4; `coordinate_activity`, `coordinate_provenance`, `coordinate_graph` |
| "The log turns every heist into a readable narrative afterward" | The signature-audit file: effect, re-derived materialization, every approval graded, settlement as external reads, verifiable from the file alone | `coordination/audit.nim`, `coordinate_audit` / `coordinate_verify_audit` |
| The killmail: automatic, attributed, factual | The audit file and log proof are generated from the log (automatic), name who signed (attributed, ADR-015 retired anonymity), and state what happened, never what it means | `log/proof.nim`; inv 9 |
| Witness by default, publish by consent | The room is the boundary; provenance is readable only inside it (FS-10); a member may share a proof or audit file outside, and that is *their* act | inv 7, inv 10; the split receipt (exo-dcc.7) is already "a receipt the member chooses to share" |
| The system secures process, never intent | Muster proves *what was agreed* (inv 1) and *where its inputs came from* (inv 10), never whether it was wise. A treasurer with keys can still drain the treasury, and the log says so | inv 1, inv 10 |
| Destructive acts need several keys | Safe, Bitcoin multisig, LEZ multisig and FROST drivers; decline is final | `drivers/`, exo-a50 |
| Deeds, not scores | Offers and readiness grade only *your own* holdings, "never a score or rank"; credibility is classified per link (imperative / motivational / exposed), never scored | inv 9; action manifest M8 |
| Legible borders, the city gate | The card's five questions: what it does, what it needs, what it touches, who will see what (the store node always listed), how we agree. Plus the flow view of who could see what, entry by entry | `coordinate_readiness`, `coordinate_flow`, `MusterCard.qml` |
| Interdependence as a completion condition | A k-of-n intent cannot be completed alone, structurally | the threshold seam; `describeFor` |
| The honest trade: a genuine counterparty | A split part is confirmed only by the creditor's own chain read; "I paid" stays a claim | `coordination/parts*.nim` |
| GUI as a living roadmap | The action atlas already lists actions that are declared but not built, each with its sources | `contracts/actions/`, the atlas |
| No server, no telemetry | inv 8 | — |

The deepest fit is the third and fifth rows together. Jarrad's corpus wants a betrayal surface that
stays *legal but auditable*. Muster's invariants deliver exactly that and refuse to deliver more:
nothing in the core decides that an approved act was a betrayal, and nothing hides that it happened.

## The law partition, Muster's column

Jarrad's room has to sort {MEV, contract exploits, social-engineering scams, sybil, vote-buying,
doxing, DDoS} into coded-impossible, legal crime and sanctioned. Muster can hand them the
coded-impossible list for everything inside its scope, because those are invariants with tests:

- **Coded-impossible:** forging another member's approval; replaying a signature in another
  environment, account, slot or after expiry (inv 2); signing bytes that differ from the reviewed
  effect (inv 1); signing over an input whose origin can't be accounted for (inv 10); a later
  joiner reading earlier epochs (inv 7); a plugin signing or touching the network (inv 3); an
  outsider learning who is in a room from the store node (exo-661.7).
- **Legal, and auditable:** a keyholder doing something the room approved and later regrets;
  infiltrating a room and earning admission honestly; collusion among k signers; a creditor
  proposing a split nobody needed. All of it lands in the log with names attached.
- **Not Muster's to decide:** anything about what an act *meant*. That belongs to the governance
  layer and the chronicle.

## The gaps, as a development path

Ordered so that each slice is useful alone and the next one builds on it.

### A. The deed: Logos's killmail, with consent

Today a member can export the *whole* audit file or log proof. That is a disclosure of everything
they hold, and it can be verified only by someone with the epoch keys (for the proof) or the file in
hand. A killmail needs something narrower: **a record of one event, carrying only the fields the
people it names agreed to publish, verifiable by anyone outside the room.**

The shape follows from what already exists. A deed is a new effect family (`muster.effect.deed.v1`)
whose effect is the publishable record: what happened, which log entries it attests to (by content
id, so the room can check it against its own log), the fields chosen, and the names it carries. Its
policy is the one the split already uses, where *every party named must agree* (`describeFor`, the
creditor-agrees rule of exo-770). That is invariant 9 turned into a mechanism: the record says about
a member only what that member agreed to say. The output is a signed artifact, domain-separated like
every other hash, that verifies with public keys alone. It is the split receipt generalized.

Examples from Jarrad's own list: this circle funded that campaign; this steward onboarded forty
people (each confirmation is the helped party's own); this org won that treasury round. A loss is
also a deed. The corpus asks for losses to be commemorated as first-class records.

Open for design: how a deed proves its entries belong to a real room without disclosing the room
(the bare content ids do not prove that alone); how a named member signs as a persistent public
pseudonym rather than their room key (below, under identity); and whether anyone can revoke a
published deed. (Probably not: irreversibility is stage 4.)

### B. The chronicle feed

A deed with nowhere to land is a file on someone's disk. The chronicle needs an open feed that third
parties can build boards on, with permalinks that never die. Under inv 8 there is no Muster server,
so the feed is a public delivery topic, Logos Storage, or both (FileShare already rides storage).
Muster's part is to publish and verify. The killboards, the "Logos Herald" and the leaderboards Jarrad
wants available as a generic component are what *others* build on the feed. That keeps Muster on the
right side of the "feed the press, never edit it" doctrine. Residual leak to name honestly: the
store node sees the publisher's address unless the send goes over mix (exo-dcc.4).

### C. Org machinery on a room

A room today is flat: any member may admit, any member may propose, and the policy is chosen per
proposal. System 13 asks for more, and most of it fits "the room's capabilities evolve by proposal"
(vision, layer 3):

1. **A charter**: a founding entry in the log naming the room, its purpose, its roles and its rule
   set. It is changed only by a proposal under the rule for changing rules. It is configuration,
   never a type field. The circle becomes a charter template.
2. **Roles and per-action policy**: a table from action class to driver and threshold. For example,
   treasury spend needs the Safe at 3-of-5 plus a 48-hour delay, admitting needs any member, and
   removal needs two officers. Roles get names the players choose; the core sees only slots.
3. **Removing a member over the wire.** The epoch layer can remove a member (`removeMember`, F-16),
   but no hosted method does it: `coordinate_leave` is local and re-keys nothing. Expulsion is an
   org act, so it needs a hosted method that runs under the charter's rule.
4. **Delay with a visible pending notice that any keyholder can cancel.** Today an executable
   intent can be submitted at once. A delay policy (executable after T, cancelled by any named
   keyholder's decline) prices a heist without preventing it, which is what the corpus asks for.
5. **Succession**: an inactivity rule in the charter (if no officer acts for N days, a named
   fallback threshold may rotate the signers). For a Safe, rotating owners is already an ordinary
   Safe transaction to itself. Other account families have not been checked.
6. **Federation**: an alliance room whose members are delegates of member rooms. A delegate acts
   under a *mandate*, which is a deed (slice A) the member room's threshold signed. So the deed
   artifact also serves as the inter-room credential, and rooms stop being islands without any room
   reading another's log.

### D. Thresholds and mutual stake: the circle itself

A ROSCA is already almost a Muster primitive. One round is a split with the `each` locus: the
round's recipient is the creditor, every other member owes an equal share, each pays their own
part, and the recipient's own chain read confirms each part. A circle is a charter with a rotation
schedule over those rounds. Muster already enforces what makes ROSCAs work: confirmation by the
counterparty, a payment in flight never paid twice, and expiry and renewal.

BRAC's commitment threshold is a predicate over reduce(log): rounds completed, deeds earned, tenure
in epochs, funds pooled to the room's account. A capability gated on it (eligibility for a treasury
round, say) is graded the way readiness already grades requirements. It is type-blind, as Jarrad's
lint rule demands: a dev collective meets it with shipped deeds and a savings circle with pooled funds.

### E. Treasury rounds: the placed asteroid

A recurring, contested allocation is a room (the pool, holding a Safe or a FROST account) that takes
proposals *from other rooms*, presented through a mandate deed, and settles the winners under its
charter. Every collision lands in the pool's log, and the outcome can become a deed on the
chronicle feed. This needs A and C.6 first. The operator-neutrality rule (the foundation never
picks) becomes a charter property anyone can read.

### F. Quests

A person-given quest is an intent. The giver proposes the task. The taker accepts it (their
agreement, as in a split). Completion is confirmed by a named confirmer, and the deed follows. The
Welcomer's Round is the important case: the welcomer's standing is recorded only on the helped
party's confirmation, which is the split's "the creditor confirms from their own read" applied to
social value. Muster's first session already has the corridor's shape: a solo act (your identity
and a room over your own node), an honest trade (a first split or send with a real counterparty),
and a shared load (a first k-of-n approval). The education mission is the tutorial interior.

### G. The UI

The desktop redesign (exo-720) already covers several surfaces of Jarrad's EVE-shell inventory. Home
is the objectives tracker (needs you / waiting on others / settled). The room map is the local map.
The flow view and the card are the band indicator and the city gate. The audit export is the
exportable log. Missing: the org window (charter, roles, standings), a profile that shows deeds
rather than numbers, the chronicle feed, welcomer surfaces, and stub cards for actions not yet
built (the atlas data already exists).

## Identity: the one hard problem

Deeds have to bind to a name that can't be shed, and pseudonymity has to protect the member, both at
once. Inside a room Muster already settles this: membership is named and persistent, and the
encryption identity is bound to the authorization key by a signed link statement (F-14). Outside the
room the open question is which public pseudonym a deed is signed under. If it is the room key,
every deed links every room the member is in. If it is a fresh key per deed, deeds bind nothing.
The likely answer is personas the member chooses: one or more public signing identities, each bound
to the member's room identity by a statement that is disclosed only inside the room where the deed
was made. The member then decides which deeds accumulate under which name. Sybil resistance under
privacy (RLN membership is the platform's nearest tool) is a platform question that Muster can use
but should not try to answer alone.

## What Muster should not become

- **Not the world.** Basecamp is the world. Muster supplies its orgs, its ledger and its witnesses.
  World rules that render or simulate (games, lotteries, quests with in-world logic) belong in
  plugins that emit typed blocks and proposed effects (F-12, inv 3), and the plugin runtime is P5.
- **Not a scorekeeper.** Leaderboards and rankings are views over the chronicle that chroniclers
  build. The core never computes a verdict about a member (inv 9).
- **Not a presence oracle.** EVE's Local channel, where presence works as intelligence, is
  impossible from outside a room by design (exo-661.7). Inside, the roster is visible. That matches
  the P4 interior and should stay that way.
- **Not the judge.** The audit file can settle an *evidence* dispute. It never says who was right.

## A first vertical slice

**A savings circle in a room, ending in a deed.** A charter template (members, rotation, share,
cadence, the rule for changing rules). Rotating rounds as `each`-locus splits. At completion, a deed
the members agree to publish: "this circle of N completed M rounds", with each name on it only by
that member's consent, verifiable outside the room. It uses what exists (split, parts,
confirmation, the audit file, the receipt) and builds the three pieces everything else needs: the
charter (C.1), the threshold predicate (D) and the deed (A). It also puts BRAC's lineage, the origin
story Jarrad wants circles to carry, into running code.

## Questions to bring back to Jarrad

1. Which fields of a circle's deed should be publishable by default, and which only by opt-in? This
   is the consent-granularity fork the UI page flags as "the load-bearing Logos-vs-ANVIL delta."
2. Is a public delivery topic an acceptable home for the chronicle feed, given that the store node
   sees who publishes unless mix is on?
3. Should the charter be something only Muster rooms know about, or a Basecamp-level org object that
   Muster rooms implement?
4. Treasury rounds: is there an actual pool (the foundation's, or a zone's) that could be the first
   placed asteroid, so the slice after the circle has a real counterparty?
5. Which of the coded-impossible list above should go into the constitution as written, ahead of
   the first heist?
