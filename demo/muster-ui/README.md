# logos-chat-ui

A QML + C++ backend UI module for the [Logos](https://logos.co) platform that provides a private messaging interface built on top of [Logos Chat](https://github.com/logos-messaging/libchat).

The UI connects to [`logos-chat-module`](https://github.com/logos-co/logos-chat-module) via the Logos Core module system for all chat operations — identity, conversations, and message exchange happen over the Logos network.

Built with [`logos-module-builder`](https://github.com/logos-co/logos-module-builder) using the `mkLogosQmlModule` pattern (QML frontend + C++ backend with Qt Remote Objects).

## What It Does

![A direct conversation in the chat UI](docs/images/exchange/05-bob-roundtrip.png)

The application provides a dark-themed chat interface laid out as cards on an
inset background: a conversations card over your account card (left), the
message thread (center), and a right column that appears for a group or when
the conversation's details are open:

- **Conversations** (left) — active conversations with an avatar, a preview, a timestamp and an unread badge, under the **New chat** button, with your own account card beneath them
- **Message thread** (center) — a header naming the conversation and who is in it, the messages, and the composer; an incoming message carries its sender's avatar and name where a run of theirs begins
- **Right column** — the group's roster with **Add member** pinned to its foot, and the conversation's **Details** panel above it while the header's toggle is on

Core functionality:

- **Identity** — on startup, initializes a chat identity; the account card at the foot of the sidebar shows the account's short form and its connection state
- **Addresses** — your own address sits on the account card with a copy button beside it; share it with others to let them start a conversation with you
- **Direct messages** — paste another user's address into **New chat > Direct message** to open a private (1:1) conversation
- **Group conversations** — start a group with **New chat > Group**, then invite peers by address from the members panel (see below)
- **Messaging** — send and receive messages in real-time over the Logos network
- **Chat lifecycle** — auto-initializes and starts on launch; the connection state shows on the account card

Conversations are **ephemeral** — messages and identity exist only while the app is running.

### Group conversations

- **New chat > Group** asks for a name and an optional description, neither of which can be changed later, then creates the group with you as its only member.
- Collect peers' addresses (each copies theirs from their account card), paste one into **Add member** at the foot of the members card, and confirm to invite.
- Membership changes are asynchronous: on devnet the group's steward commits an add only after a ~60s commit-inactivity window, then the welcome is delivered, so a peer joins **minutes** after the invite. A peer you invited sits on the roster as a dimmed row reading **Waiting to join** until the group commits it, and stays there across chat switches. The roster refreshes on selection, a message from a new member, or your own add.
- A right-click on a roster row offers **Copy address**, for passing a member's address on.
- Any member can add another; the invite routes from whoever proposed it.
- During the brief windows while the group is finalizing a membership change, de-mls rejects sends; these surface on the status bar at the foot of the window, so retry after a moment.

## How to Run

### Standalone (recommended for development)

```bash
# Run directly
nix run

# With local workspace overrides (if testing local changes)
nix run --override-input chat_module path:../logos-chat-module \
        --override-input chat_module/logos-module-builder path:../logos-module-builder
```

The standalone app starts Logos Core, loads `capability_module` and `chat_module`, then launches the QML UI via an isolated `ui-host` process.

### Running multiple instances on one machine

To try a real conversation or group locally, run two or more standalone apps
side by side on the same host. Each instance needs its own session directory;
the UI-to-backend QtRO socket name is randomized per instance and the delivery
node listens on ports it picks itself, so nothing else has to be set:

```bash
# window A
nix run . -- --user-dir ~/.local/share/chat_a
# window B
nix run . -- --user-dir ~/.local/share/chat_b
```

Add further windows the same way, giving each a fresh session directory
(`chat_c`, and so on).

The standalone app hands every module its own directory under
`<session dir>/module_data`, so `--user-dir` is what keeps two instances' chat
state apart; it defaults to the platform application data location.

| Variable | Purpose |
|---|---|
| `LOGOS_USER_DIR` | The standalone app's session directory, for when setting it by environment is easier than by flag. `--user-dir` wins over it. |
| `QML_INSPECTOR_PORT` | Only needed when attaching the [logos-qt-mcp](https://github.com/logos-co/logos-qt-mcp) inspector to drive an instance programmatically (default 3768); give each a distinct one then. Interactive use does not need it. |

Each node joins the `logos.test` messaging fleet and publishes its key package during
init, so this needs internet and ~5-20s per window to reach **Online**. Then
copy one window's address from its account card and paste it into another
(**New chat > Direct message** for a 1:1, or **New chat > Group** then the members
panel for a group). For
the full walkthrough with screenshots, and the scripted drivers that automate it
(`doctests/exchange/run-exchange.sh` for a two-party exchange,
`doctests/group/run-group.sh` for a three-party group), see
[Two-instance message exchange](docs/two-instance-exchange.md).

### In Basecamp

Build the `.lgx` package and install it:

```bash
# Build LGX
nix build .#lgx

# Install into Basecamp's plugin directory
lgpm --ui-plugins-dir ~/Library/Application\ Support/Logos/LogosBasecampDev/plugins \
     install --file result/*.lgx
```

Or from the workspace:

```bash
ws bundle logos-chat-ui --auto-local
```

### Build Targets

```bash
nix build            # default — combined plugin + QML output
nix build .#lgx      # .lgx package for distribution
nix build .#install  # lgpm-installed output (modules/ + plugins/)
nix run              # standalone app with chat_module
nix develop          # enter development shell
```

## Documentation

- [Two-instance message exchange](docs/two-instance-exchange.md) — two windows
  exchanging encrypted messages end-to-end (with screenshots), plus how to run
  two instances locally.
- Doc-test tutorials — executable walkthroughs that CI runs and publishes as an
  HTML report under `https://logos-co.github.io/logos-chat-ui/`:
  [The Logos Chat UI](doctests/chat-ui.test.yaml) (connect + share your
  address) and
  [Run the automated message-exchange test](doctests/chat-ui-exchange.test.yaml)
  (the real two-party round-trip, captured).

  Enabling the report links is a one-time repo setup: Settings -> Pages ->
  "Deploy from a branch", branch `gh-pages` / `(root)` (the CI publish-report
  job creates the `gh-pages` branch on its first run).

## Module Structure

```
logos-chat-ui/
├── flake.nix                  # mkLogosQmlModule
├── metadata.json              # Module config (ui_qml, interface: universal)
├── CMakeLists.txt             # logos_module() macro
└── src/
    ├── ChatBackend.rep        # QtRO interface (ChatStatus enum, props, slots, signals)
    ├── ChatBackend.h/cpp      # Backend: chat lifecycle, conversations, messages
    ├── ConversationListModel.h/cpp  # QAbstractListModel for conversations
    ├── MessageListModel.h/cpp       # QAbstractListModel for messages
    ├── MemberListModel.h/cpp        # QAbstractListModel for a group's roster
    ├── Identity.h/cpp               # Avatar initials + colour ramp for an address
    ├── TimeFormat.h/cpp             # Clock-time and day-label formatting
    ├── ErrorLog.h/cpp               # The run's failures, newest first, repeats collapsed
    ├── RunLog.h/cpp                 # This view's log file, rotated and pruned
    ├── ProcessLog.h/cpp             # Qt's messages into that file, buffered until it opens
    ├── SessionLogFiles.h/cpp        # A log directory grouped into runs, per writer
    └── qml/
        ├── ChatView.qml       # Top-level composition (thin)
        └── ChatUi/            # Pure-QML component module, built on Logos.Theme
            ├── ChatStore.qml          # Sole reader of the injected logos context
            ├── ConversationsPane.qml  # Conversations card + account card (left)
            ├── MessageThreadPane.qml  # Message thread + composer (center)
            ├── ThreadHeader.qml       # Conversation name, facepile, details toggle
            ├── DetailsPanel.qml       # The conversation's facts (right, on demand)
            ├── MembersPane.qml        # Group roster + add-member (right)
            ├── ...                    # dialogs, delegates, leaf components
            └── qmldir
```

The plugin entry point and QtRO replica/source glue are generated by
`mkLogosQmlModule` from `metadata.json#codegen` (`rep` / `backend_class` /
`backend_header`); the repo carries the backend, the three models, and the QML
view module.

### Key Components

| File | Role |
|------|------|
| `ChatBackend.rep` | Defines the C++/QML boundary — `ChatStatus` enum, state props, lifecycle slots, signals |
| `ChatBackend` | Derives `ChatBackendSimpleSource` + `LogosUiPluginContext`; initialises the module and subscribes to `chat_module` events in `onContextReady()`; drives the three models |
| `ConversationListModel` | A row per conversation: its id, display name, kind, description, last activity and the label for it, message preview, unread count, avatar |
| `MessageListModel` | A row per message: sender, content, timestamp and the label for it, whether it is yours, where a run of one sender and a new day begin, avatar |
| `MemberListModel` | A row per member: address, label, whether it is you, whether the invite is still uncommitted, avatar |
| `Identity` | Derives a row's initials and colour ramp from an address, in one place, so an account keeps its avatar across every list |
| `TimeFormat` | The single formatter for clock times and day labels, so no view formats its own |
| `ErrorLog` | Every failure the run reported, newest first, consecutive repeats collapsed to one row with a count |
| `RunLog` / `ProcessLog` | This view's own log: `ProcessLog` catches everything Qt logs and holds it until a directory is known, `RunLog` writes, rotates and prunes it |
| `SessionLogFiles` | Groups a log directory into runs by the stem of the announced file, which is what lets two writers share one directory |

## Logs

Two writers keep a log of this run, both in the chat module's instance
directory. The chat module was assigned that directory; this view borrows it,
because the platform assigns a view module none of its own
(`LogosUiPluginContext` has no `instancePersistencePath`) and picking one would
mean two instances of the app writing into the same folder. The **Show logs**
button at the foot of the window lists both, a tab per writer, alongside every
failure the run reported.

Each writer's files are `<stem>_<stamp>.log` for the file being written and
`<stem>_<stamp>.NNN.log` for a rotation of it, ten runs kept. A list is grouped
by the stem of the file its own writer announced, so `chat_ui`'s runs and
`chat_module`'s never pick up each other's.

Delivery has no tab of its own yet: `delivery_module` writes to stderr and the
node embedded in it to stdout, both wherever the process was started from. The
tab is there and says so.

## Requirements

> [!TIP]
> When using Nix, all requirements are acquired automatically.

### Dependencies

| Dependency | Purpose |
|---|---|
| Qt6 Core, RemoteObjects, Declarative | UI framework + IPC |
| [`logos-module-builder`](https://github.com/logos-co/logos-module-builder) | Build system (mkLogosQmlModule) |
| [`logos-chat-module`](https://github.com/logos-co/logos-chat-module) | Chat backend module |
| [`logos-delivery-module`](https://github.com/logos-co/logos-delivery-module) | Transport (Logos Messaging) — runtime dependency, pinned at v0.1.3 |

## Related Repositories

| Repository | Role |
|---|---|
| [`logos-chat-module`](https://github.com/logos-co/logos-chat-module) | Chat backend — this UI's required dependency |
| [`logos-delivery-module`](https://github.com/logos-co/logos-delivery-module) | Transport (Logos Messaging) — runtime dependency, pinned at v0.1.3 |
| [`libchat`](https://github.com/logos-messaging/libchat) | Chat engine embedded by `chat_module` (E2EE, sessions) |
| [`logos-module-builder`](https://github.com/logos-co/logos-module-builder) | Module build system |
| [`logos-liblogos`](https://github.com/logos-co/logos-liblogos) | Logos Core platform |
