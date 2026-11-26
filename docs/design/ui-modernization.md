# Modernizing Muster's UI: a chat client first, the lifecycle on demand

**Status:** plan agreed 2026-10-09 (§6). U0b–U8 built (2026-10-09/11), each checked in the gallery and, for what the gallery cannot show, in the real runner; U0a done in the runner, then in Basecamp 0.3.2 (`ea2d1bc9`, 2026-10-12: Muster launches there after one fix). Epic `exo-720` and U0a (`exo-720.1`, whose scope named the Nim host too) are closed; the Nim UI runs the same QML through `scripts/ui-parity.sh` (`MUSTER_UI=nim`). Still deferred: the U-6 membership seams (`exo-c15`). §7–§9 record what each slice found and what was deferred.
**Reads with:** `docs/01-furps.md` (U-1 to U-10), `ui/prototype/coordination-prototype-v2.html` (the reference build), `docs/labbook/qml-errors-are-invisible-to-nix-build.md`, `docs/design/seaqt-ui.md` (the QML is kept when the backend moves to Nim, so this work carries over).

## 1. What was asked

The interface is clunky and hard to navigate next to a modern chat client. The right panel takes too much space, and its sections are hard to tell apart. The goal is a UI that is intuitive and useful but stays out of the way.

## 2. What is wrong today

These were read from the QML on `main` (`d3b81a4`).

**The shell is a row of buttons.** `Main.qml` has a top bar of seven equal buttons: Home, Room, Account, Walkthrough, Settings, Contacts, Send λ. There is no room list. You reach a room only through Home, and "Room" shows whichever room you opened last. Every chat client people know puts the rooms in a left column and the conversation in the main pane.

**The right panel is a fixed 320 px column with five stacked sections.** In `Room.qml` (lines 3520–3660) these are:

1. connection indicators;
2. room accounts, with the Safe, Bitcoin, FROST and LEZ multisig forms (in a scroller of its own);
3. the activity feed;
4. the information-flow view;
5. the scope panel: roster, join requests, and Admit.

They are split only by 1 px rules, and each scrolls on its own. The column is always open, whether or not the person needs any of it.

**The room column carries everything else.** The header has the title, Rename, Leave, and the member count in 8 px mono text. The full room code sits on a row of its own. The proposal composer is about 1,200 lines of forms (`Room.qml` 2045–3290) inline above the message bar. Below those forms sit about fifteen feedback rows, each a `LogosText` starting with ⚠ or ⏳, for split, Monero, Bitcoin, LEZ, and approval outcomes. They stack above the message field, and some of them never clear (exo-408 #7).

**Three controls carry the whole app.** Muster uses 3 of the design system's 37 controls: `LogosText` (308 uses), `LogosButton` (261), and `LogosTextField` (55). It uses none of `LogosDrawer`, `LogosIconButton`, `LogosMenu`, `LogosTabBar`, `LogosBadge`, `LogosIcon`, `LogosToolTip`, `LogosDialog`, or `LogosScrollView`. So every action is a labelled button of the same weight, there are no icons, and nothing is tucked into a menu. This was a deliberate precaution. A QML error blanks a view without failing `nix build`, so `Home.qml` limited itself to the types already proven to render. It is the main reason the app looks unfinished.

**Body text is set at 8 px.** `Theme.typography.badgeText` is 8 px. It is used 221 times: 66 in `MusterCard.qml`, 48 in `Room.qml`, 34 in `Settings.qml`. That covers the room code, the member count, every feedback line, and much of the card. Section differences come only from these 8 px captions and the hairline rules.

**Two files hold most of it.** `Room.qml` is 3,703 lines and `MusterCard.qml` is 2,498, out of 11,966 lines of QML in total. Nothing in the layout can change cheaply until they are split up.

**The QML has drifted from the prototype and from FURPS.** The prototype already has the shape this plan wants:

- a room header with an account chip;
- a nameplate that opens a "Who can see this" sheet;
- a pinned live proposal (U-3);
- a one-line composer whose `+` opens a sheet of actions;
- the scope line under it (U-1).

The QML added each new capability (accounts, FROST, LEZ, flow, Monero) as another stacked section instead.

## 3. Where we want to land

The pattern is the one Signal Desktop, Element, and Slack share: rooms on the left, the conversation in the middle, and details on the right only when asked for.

```
┌──────────────┬─────────────────────────────────────────────┬───────────────────┐
│ ● Needs you 2│ Dinner at Ana's      ◉◉◉ 3   ● live   Invite ⋯ │ Room details    × │
│              ├─────────────────────────────────────────────┤ People│Accounts│  │
│ ROOMS        │ ▸ Split 0.12 ETH · 1 of 3 agreed     [Agree]  │ History│Privacy   │
│ Dinner  ●    ├─────────────────────────────────────────────┤                   │
│ Safe ops     │  ana: who's in for Friday?                    │  (closed by       │
│ Rent split   │  ── bob joined · epoch 2 ──                   │   default; opens  │
│              │  ┌ Split a bill ─────────────────────┐        │   from the header,│
│ + New        │  │ 0.12 ETH · you owe 0.04  ○●○ 1/3  │        │   a card's "Who   │
│              │  │ [Agree to my share]   Details ⌄  │        │   sees this?", or │
│ ──────────── │  └───────────────────────────────────┘        │   a refusal that  │
│ Wallet       ├─────────────────────────────────────────────┤   names it)       │
│ Contacts     │ [+] Say something                     [Send] │                   │
│ Learn  ⚙     │ 3 can read · nothing leaves the room yet    │                   │
└──────────────┴─────────────────────────────────────────────┴───────────────────┘
```

**Design rules:**

- **The conversation owns the screen.** Anything else on screen has to justify itself against FURPS. U-1 (the scope line), U-3 (the pinned live proposal), U-5 (the provenance grade on the card), and U-8 (blocked states explained inline) stay always visible. Everything else is one click away.
- **Move the educational layer, never remove it.** Every fact the right panel shows today stays reachable in one click. Where possible it is reached from the thing it explains: a card's "Who sees this?" opens Privacy filtered to that intent. Explaining a fact where it applies teaches better than a permanent sidebar does.
- **One primary action per view.** Secondary actions become icon buttons, ⋯ menus, or links.
- **Typography carries hierarchy.** Use panelTitle (24) or subtitle (16) for headings, primary (14) for body, and secondary (12) for captions. badgeText (8) is for badges only. Use mono only for codes, hashes, and addresses. Mark sections with headings and surface levels, not with rules.
- **Feedback lives where the action happened.** A form's outcome shows in the form. A card's outcome shows on the card. Transient confirmations go to a toast. The space above the message bar is not a log.
- **The module does not change.** This is a QML change. Panel open/closed, the selected tab, and the sidebar state stay in the view. A layout preference is kept on the device, never in the room.

## 4. Slices

Each slice ends with the parity suite green (`scripts/ui-parity.sh`, `MUSTER_UI=cpp`) and with screenshots at three sizes, compared against the baseline from U0b. Every moved element keeps its `objectName`: the qt-mcp harness and the self-tests address 276 of them.

### U0: groundwork (no visual change)

- **U0a: control census.** Build one throwaway view that uses each control we plan to adopt: Drawer, IconButton, Menu, TabBar, Badge, Icon, ToolTip, Dialog, ScrollView, ItemDelegate. Show that each renders in three places:
  - the standalone runner, offscreen;
  - the Nim host (`ui-nim/app`);
  - Basecamp 0.3.2.

  Record the result in a labbook entry. Lift the "LogosText + LogosButton only" note in `Home.qml` for the controls that pass. Add `qmllint` over `ui/src/qml/**` to `run-suite.sh`.
- **U0b: screenshot harness.** Add `scripts/ui-screenshot.sh`. It runs the offscreen runner with `grabToImage` to PNG for a fixed set of states:
  - Home, empty;
  - Home with rows;
  - a room with a split card;
  - a room with a join request;
  - a room with a proposal refused.

  It shoots each at 1024×700, 1440×900, and 1920×1080. Take the baseline before anything changes. This answers "does it look right", which `nix build` cannot.
- **U0c: decompose.** Split the two large files, moving code only:
  - `Room.qml` → `RoomHeader`, `RoomThread`, `RoomComposer`, `RoomDetails` (today's right column), `compose/SplitForm`, `compose/PaymentForm`, `compose/BitcoinForm`, `compose/LezForm`, `compose/ActionForm`, `compose/MoneroRequestForm`, and `RoomNotices`.
  - `MusterCard.qml` → `CardHeader`, `CardRail`, `CardApprovals`, `CardDetails`, `CardActions`.

  The screenshots must be identical before and after.
- **U0d: the desktop mockup.** A new reference build, `ui/prototype/desktop-v3.html`, with the target in §3. This is where the look gets decided. It takes minutes per iteration in HTML against a build per iteration in QML. It is a new file, not a frame added to `coordination-prototype-v2.html`, for two reasons:
  - v2's palette (paper, ink, violet) is not what the QML renders. The QML is built on `Logos.Theme` (ADR-011): dark only, orange primary, Public Sans. v3 uses those exact token values, so each element ports one to one.
  - v2 simulates the room of 2026-08: one account per room, no splits, no join requests, no connectivity or flow view. v3 carries the surfaces the QML has today, rearranged.

  v2 stays as the reference for the lifecycle and copy voice. v3 is the reference for layout, and supersedes v2 where they differ.

### U1: the visual foundation

Add `ui/src/qml/components/`:

- `SectionHeader`;
- `Surface` (three elevation levels from palette tokens);
- `StatusPill` (needs-you, waiting, settled, blocked, refused);
- `Avatar`: an identicon from the member id, with the local alias's initial. It shows only what the member disclosed (invariant 9).
- `InlineNotice`: info, warn, or error, with remedy buttons. This replaces the ad-hoc ⚠/⏳ text rows; `Room.qml` alone has 43 such strings.
- `EmptyState`;
- `Toast`;
- `IconAction`: an icon button with a tooltip.

Add a small SVG icon set for what `Logos.Icons` lacks: people, shield, eye, key, wallet, chain, info, settings, and send. `Logos.Icons` has only 17 icons.

Apply the type rule from §3 across the codebase.

### U2: the app shell

Replace the top nav with a left sidebar:

- **Needs you** at the top, with a count badge. This is Home's F-18 action list, which becomes a view of its own.
- **Rooms**: title, last activity, and a needs-you dot.
- **+ New**: today's Composer, as a dialog.
- **At the bottom:**
  - Wallet: today's Account and Send λ together. The anvil Safe dashboard moves behind a dev setting.
  - Contacts.
  - Learn: the Walkthrough.
  - Settings.

The sidebar collapses to an icon rail. Below about 900 px it becomes a drawer. **Basecamp already has its own app sidebar**, so inside Basecamp ours starts as the rail (see §6, question 1).

### U3: the room's chrome

- **Header:**
  - the title (click to rename inline);
  - member faces and a count, which open People;
  - a connection dot that opens a popover with today's `ConnectionIndicators`, and turns into a thread banner only when something is down;
  - **Invite**: a popover with the room code, copy, and invite-a-contact;
  - a **⋯ menu**: Rename, Room details, Leave. Leave keeps the exo-dcc.28 wording, in a `LogosDialog`.
- **The pinned live proposal** (U-3): one line with its state and a jump to the card.
- **The scope line** under the composer (U-1): "3 can read · nothing has left the room".
- **In the thread:**
  - membership seams (U-6);
  - join requests as a notice with **Admit**, where the action already is, instead of in the side panel.

### U4: room details, on demand

The right column becomes a drawer, closed by default. It docks at 1280 px and wider and overlays the thread below that. It has four tabs:

- **People:** the roster, pending requests, and security levels (today's ScopePanel).
- **Accounts:** RoomAccounts with its Safe, Bitcoin, FROST, and LEZ forms.
- **History:** the ActivityFeed.
- **Privacy:** the FlowView, as "who can see what".

These open it at the right tab:

- a card's "Who sees this?" opens Privacy, filtered to that intent;
- a `no-account` refusal opens Accounts with the form already open (today's `wantedFamilies`);
- a request to join opens People.

Its open or closed state is remembered per device.

### U5: proposing

The `+` in the message bar opens an action picker: a grid of verbs with icons, labelled by the driver (U-7). It reuses the module's action menu. Choosing a verb opens that kind's form from U0c in a sheet over the thread, so the thread is never pushed down.

The form shows its own outcome as an `InlineNotice`, including the Monero, Bitcoin, and LEZ refusals and their remedy buttons. The outcome clears when the form succeeds or closes, which settles exo-408 #7's "last result never clears" for good. The vote-pending and approval-refusal lines move onto the card they belong to.

### U6: cards

A card is compact by default:

- a kind icon and title;
- the headline amount, or "you owe";
- a `StatusPill`;
- approval faces filling as they arrive (U-4);
- the provenance grade and the re-derived-match mark (U-5, invariant 1);
- one primary action, with the rest in ⋯.

**Details** expands to the five questions, readiness, the verify box, hashes, and provenance, exactly as they are today. Blocked states keep their cause and remedy on the compact face (U-8).

Fold in the open exo-408 card items: #2, #5, #8, and #13.

### U7: the other surfaces

- **Wallet:** balances across chains with the verified/attested badges, and the LEZ send.
- **Settings:** grouped sections with a sub-navigation: identity, network, chains, signer, mixnet, and advanced.
- **Contacts:** a list with avatars and inline editing.
- **New room:** a dialog of verb → people → account, as in the prototype.

### U8: keyboard and accessibility (U-10)

- Ctrl+K switches rooms.
- Esc closes a sheet, drawer, or popover.
- Ctrl+Enter proposes.
- Focus order and visible focus throughout.
- A pass of the palette for AA contrast in both themes.
- Reduced motion respected.
- U-2's change of ground when crossing the boundary is checked on the submitted card.

**Order.** U0 comes first, and U0a–U0d can run in parallel. U1 follows. U2, U3, and U4 can then proceed side by side; they touch `Main.qml`, the room header, and the room details respectively. U5 and U6 follow U1. U7 and U8 come last.

## 5. What could go wrong

- **A blank view that ships green.** Every slice runs qmllint (U0a) and the screenshot harness (U0b). Any slice that touches a view Basecamp hosts is also looked at in Basecamp, not only in the runner.
- **Losing the education.** Before U4 merges, list every fact today's right panel shows, and the one-click path to each in the new layout. Store the list with the slice's PR.
- **Losing the self-tests.** `objectName`s move with their elements. A self-test that relies on something being visible, such as Admit in the side panel, is updated in the same PR.
- **A conflict with exo-607 (the Nim backend).** None is expected. The QML and the `.rep` contract are shared, and this plan changes neither the contract nor the module.
- **A double sidebar inside Basecamp.** This is a real UX risk. It is handled by starting collapsed (U2) and by question 1.

## 6. Decisions (2026-10-09)

1. **In Basecamp, a second sidebar, or a room switcher in the header?** The collapsible rail. It is what people expect from a chat client, and it costs about 56 px when collapsed.
2. **Mock up first or build first?** Mock up first (U0d): settle the look in HTML, then port it.
3. **The anvil Safe dashboard ("Account").** Hidden behind a dev setting once the Wallet exists.
4. **The Walkthrough.** "Learn" in the sidebar, with its claims also reachable from cards in context ("How is this kept private?").

## 7. What U0 found (2026-10-09)

Details, and the traps behind them: `docs/labbook/screenshots-of-the-qml-that-hold-still.md`.

- **The harness.** `scripts/ui-screenshot.sh gallery` renders the real `Main.qml` with recorded module output, at three sizes, in about a minute, identical run to run. `record` makes the fixtures from a real self-test; `compare` pixel-diffs two sets; `census` shows the design-system controls in the real runner. `scripts/ui-lint.sh` gates new QML errors against a baseline.
- **Every control the plan names renders in the runner,** with zero QML warnings (17 of them, Drawer, Menu, Dialog and ToolTip included). So the "LogosText and LogosButton only" rule can go once Basecamp and the Nim host agree.
- **Icons need GL.** `LogosIcon` tints through `MultiEffect`, which draws nothing under the software renderer. Design rule for U1–U6: an icon-only button always has a tooltip or a label.
- **Four silent bugs in today's QML,** none caught by any build:
  - `Theme.typography.mono` does not exist (136 uses): no "monospace" text is monospace.
  - `LogosButton.Variant.Tertiary` does not exist (4 uses).
  - `Theme.palette.borderDefault` (6) and `textPrimary` (1) do not exist.

  They are the lint baseline (147 findings); U1 removes them.
- **The baseline shows the problem the plan names.** At 1440×900, a room's join request and its Admit button sit below the fold of the right panel. At the runner's default 1024×768, the top bar of seven buttons wraps to two rows.
- **The decomposition (U0c), a pure move.** `Room.qml` 3,738 → 1,321 lines (RoomHeader, RoomThread, RoomComposer, RoomDetails); `MusterCard.qml` 2,543 → 810 (CardProposal, CardNeeds, CardReceipt, CardAddressShare, CardAddressRequest, CardUnknownSchema); `RoomComposer.qml` 1,505 → 1,170 (the kind row, policy picker, needs, account picker, attest identity). All 66 gallery shots identical before and after, runtime warnings identical, `split-self-test.sh` green with the new QML live. Two things stay for later slices:
  - The payment, statement, action and split forms share their fields with one Propose row, so they move in U5, when each form gets its own sheet and Propose.
  - Sibling groups (the card's heading and actions, the composer's notices) stay where they are. Wrapping them would add layout spacing when all are hidden, which is a pixel change. U5 and U6 replace them.

## 8. U1–U4 as built (2026-10-10)

- **U1.** `MusterStyle` (a singleton in the `qmldir` we now ship) adds what Logos.Theme lacks: DM Mono, bundled; a type scale (24/16/14/12, and 11 for pills); status tints; `icon(name)` for the 33 icons in `ui/src/qml/icons/`. The shared components are `Avatar`, `StatusPill`, `SectionHeader`, `Surface`, `IconAction`, `ActionButton`, `InlineNotice`, `EmptyState` and `Toast`; the gallery's `components` fixture shows them. The 147 lint findings are fixed and the lint baseline is empty. The gallery's runtime QML warnings went from 17,181 to 0.
- **`ActionButton`** exists because LogosButton is 200×50 by default, and its Primary label is white on orange, about 2.6:1 against AA's 4.5:1. ActionButton is sized to its label, with a dark label on Primary.
- **U2.** `Sidebar` has three modes: full, a rail, and a drawer under 900 px. Until the person chooses, a window under 1180 px starts with the rail. The old nav buttons' objectNames ride on the rows that do their job.
- **U3/U4.** The room is now one header line, the pinned proposal, the thread, join requests with Admit, the composer and the scope line. `RoomDetails` is a drawer with four tabs, docked when the thread keeps 640 px or more.
- **Deferred:**
  - membership seams in the thread (U-6);
  - Privacy filtered to one proposal, and a card's own "Who sees this?" (U6);
  - which labels are monospace (the surface slices decide).
- **Checked since:** Basecamp 0.3.2 (`ea2d1bc9`, 2026-10-12); `exo-720.1` closed.

## 9. U5–U8 as built (2026-10-11), and where today's right panel went

- **U5.** "+" opens `RoomActionPicker`: Payment, Split a bill, Request a payment, Statement, Call a module. Each tile carries the old kind button's objectName. The chosen form opens in a titled panel above the message row, scrolling within about half the room. What came of a proposal, a payment or an approval is an `InlineNotice` with its remedies. It can be dismissed, and it comes back when a new outcome changes it (exo-408 #7).
- **U6.** A card has a header (the kind's icon, the heading, a `StatusPill`) and one wrapping row of actions. The action that moves the card forward is Primary; Deny, Who sees this? and Details are quiet. Labels are in the body face, and monospace is for data only.
  - **Compact by default.** The card shows what it does, the parts of a split, the approval slots and who filled them, and one proof line: "✓ Re-derived on this device · N inputs, each traced to where it came from" (U-5). Tapping the proof line opens **Details**. Details shows the status rail, the Safe call data, the rail, where the rule lives, How this account works, What this needs, the verify box, the provenance box, the trace links, and Download audit trail.
  - **Warnings stay on the face** (U-8): a DELEGATECALL, approvals pasted in from outside, a fiat quote to check, a payTo this client does not hold, a creditor who has not agreed yet, a step the chain has not included. What this needs also stays on the face once readiness names something missing or cannot be read.
  - **Opening a box opens Details.** Opening the verify box, the provenance or the account rows sets Details open, so the harness's `verifyOpen` still reveals the verify box.
  - The plan's ⋯ menu was not needed. With Download behind Details, the quiet actions fit in one row.
- **U7.** Every page opens with a `PageHeader`, aligned with the sidebar: Needs you (grouped by what it asks of you), Wallet (the Balances and Send on LEZ tabs), Contacts, Learn, Settings, Start something. Decision §6.3 needed no new switch: the local test Safe already shows only where the local dev chain answers.
- **U8.** Ctrl+K opens a room switcher (type to filter, ↑ ↓, Enter), and so does the sidebar's "Jump to…". Esc closes the drawer, else the proposal panel. ActionButton has a focus ring. Pill text clears AA (needs 5.7:1, info 6.1:1, where they were 4.4 and 3.8). These were verified in the real runner after three focus fixes: Main is the default key receiver, LogosTextField's inner input takes focus, and the switcher takes focus when it opens.
- **ui-lint.sh** now also catches a property bound twice in one object, which qmllint misses. That error fails the whole document at runtime, and it blanked every view once.

**Where each fact on today's right panel lives now** (§5's check before U4 merges):

| Shown in the old column | Where it is now, one click from the room |
|---|---|
| Connections: delivery, RPC, each with level and what introduced it | The header's dot and its popover; a banner when one is down |
| Accounts disclosed into the room, and the forms to add one | Room details › Accounts. A no-account refusal opens it. |
| Room history | Room details › History, and ⋯ › Room history |
| Who can see what | Room details › Privacy; the scope line's "Who can see what"; each card's "Who sees this?" |
| Security level (three axes, real or null) | Room details › People |
| The roster, and the scope line "end-to-end · N can read" | The header's faces (→ People); the scope line under the composer, always on screen (U-1) |
| Join requests and Admit | A notice in the conversation with Admit, a dot on the header's faces, and Room details › People |
| The room code, Rename, Leave | Invite; a click on the title; ⋯ |

**Still deferred:**
- membership seams in the thread (U-6, `exo-c15`: membership events need a time).

Checking this in Basecamp 0.3.2 was done on 2026-10-12 (`ea2d1bc9`).

Since done: Privacy filtered to one proposal (`FlowView.intentFilter`, from a card's "Who sees this?"); the compact card (U6 above); `exo-c4f` (the form names what Propose waits on).
