import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import QtCore as Prefs
import Logos.Theme
import Logos.Controls

// The home surface — the app's launch screen, and its argument in one list.
//
// People come back to *do* something (pay someone, answer a request), so the
// first thing they see is the doing: an action list bucketed by what it wants
// from them — needs-you first, then in-flight, then settled. This is F-18: a
// query over intents, not a second record. Every row is a headline the module
// already reduced ("Ready to pay", "Needs your signature", "Paid"); this view
// adds no interpretation of its own.
//
// PURE-RENDER: data in via `actions`, navigation out via `activated` /
// `newActivity`. It calls no backend and holds no state — the host wires the
// query to the fold and routes the signals.
//
// NB (ADR-011): nix build does not evaluate QML; a stray key or type blanks the
// whole view invisibly. Restricted to Theme keys + the Logos.Controls types
// Room.qml / Walkthrough.qml already prove render (LogosText, LogosButton).
Item {
    id: home

    // A parsed array of rows, already sorted by the host:
    //   { topic, title, action, state, detail, atMs }
    // where `action` is the plain-language headline and `state` is one of
    // "needs" | "waiting" | "settled" | "idle". Defaults to [] so a delegate
    // never faces undefined.
    property var actions: []

    // Room invites received on this identity's inbox: [{topic, from, fromAlias, note, ts}].
    // Someone opened a room WITH you and it reached your instance — shown at the top so
    // you can join without being told a name out-of-band. Defaults to [] for the delegate.
    property var invites: []

    // A row was clicked → open that room.
    signal activated(string topic)
    // "Start something" pressed → begin a new coordination.
    signal newActivity()
    // First run under the platform (exo-d4d.6): what is missing before money can move,
    // {show, title, detail, action: "accounts" | "settings"}. Empty = nothing to set up.
    property var setup: ({})
    signal manageAccounts()
    signal openSettings()
    signal openContacts()

    // the first-run checklist (exo-6e5): who you are, and how far along you are
    property string chatId: ""
    property int contactCount: 0
    property int roomCount: 0
    // whether the module has said which rooms there are (exo-ba0): until it has, Home says
    // it is loading, rather than show a newcomer's checklist to someone with rooms
    property bool loaded: true
    Prefs.Settings {
        id: firstRun
        category: "MusterUiFirstRun"
        property bool sharedChatId: false
        property bool hidden: false
    }
    readonly property var steps: {
        var s = [
            { key: "share", done: firstRun.sharedChatId || home.roomCount > 0,
              text: qsTr("Share your contact link, so someone can invite you to a room"), action: qsTr("Share") },
            { key: "room", done: home.roomCount > 0,
              text: qsTr("Start something, or join a room with its code"), action: qsTr("Start something") },
            { key: "contact", done: home.contactCount > 0,
              text: qsTr("Put a name to someone you know"), action: qsTr("Open Contacts") }
        ];
        // under Basecamp a fresh install has no account to pay or approve with; optional
        // until something needs it, when the notice above asks instead (exo-5a5)
        if (home.setup.show && home.setup.action === "accounts")
            s.push({ key: "account", done: false, optional: true,
                     text: qsTr("Optional: set up an Ethereum account, to pay or approve payments"),
                     action: qsTr("Create or import") });
        return s;
    }
    readonly property bool checklistDone: home.steps.every(function (x) { return x.done || x.optional; })
    readonly property bool checklistShown: home.loaded && !firstRun.hidden && !home.checklistDone
    function runStep(key) {
        if (key === "share") sharePop.open();
        else if (key === "room") home.newActivity();
        else if (key === "contact") home.openContacts();
        else if (key === "account") home.manageAccounts();
    }
    // the contact link to give someone (exo-899); copying it ticks the step off
    Popup {
        id: sharePop
        objectName: "homeSharePopup"
        anchors.centerIn: Overlay.overlay
        width: Math.min(460, home.width - 2 * Theme.spacing.large)
        modal: true
        padding: Theme.spacing.large
        background: Surface { level: 2 }
        contentItem: ColumnLayout {
            spacing: Theme.spacing.small
            LogosText {
                textFormat: Text.PlainText
                text: qsTr("Your contact link")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.subtitle
                font.weight: Theme.typography.weightBold
            }
            ShareContact {
                Layout.fillWidth: true
                chatId: home.chatId
                onCopied: firstRun.sharedChatId = true
            }
            ActionButton {
                Layout.alignment: Qt.AlignRight
                quiet: true
                text: qsTr("Done")
                onClicked: sharePop.close()
            }
        }
    }
    // A received invite's Join was clicked → open (and ask to join) that room.
    signal joinInvite(string topic)
    // join a room by the code someone shared (exo-dcc.28)
    signal joinCode(string topic)
    // A received invite's Dismiss was clicked → clear it so it stops showing.
    signal dismissInvite(string topic)

    // How many rows are waiting on the user — the number worth a heading.
    readonly property int needsCount: {
        var n = 0;
        var rows = home.actions || [];
        for (var i = 0; i < rows.length; ++i)
            if (rows[i] && rows[i].state === "needs")
                n += 1;
        return n;
    }

    // the groups, in the order they are read: what waits on you first (F-18)
    readonly property var groups: [
        { state: "needs", title: qsTr("Waits on you"), hot: true },
        { state: "waiting", title: qsTr("Waiting on others"), hot: false },
        { state: "settled", title: qsTr("Settled"), hot: false },
        { state: "idle", title: qsTr("Quiet rooms"), hot: false }
    ]
    function rowsIn(state) { return (home.actions || []).filter(function (r) { return r && r.state === state; }); }
    function tone(state) { return state === "needs" ? "needs" : state === "settled" ? "settled" : "waiting"; }

    // ── the page (exo-720.11, docs/design/ui-modernization.md §4 U7; reference
    // ui/prototype/desktop-v3.html): a title that answers "why am I here", then the doing ──
    Flickable {
        id: page
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: col.implicitHeight + 2 * Theme.spacing.xxlarge
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: col
            width: Math.min(page.width - 2 * Theme.spacing.xxlarge, 880)
            x: (page.width - width) / 2
            y: Theme.spacing.xlarge + 8
            spacing: Theme.spacing.large

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.medium
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    LogosText {
                        textFormat: Text.PlainText
                        text: qsTr("Needs you")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.title
                        font.weight: Theme.typography.weightBold
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        objectName: "homeHeadline"
                        text: home.needsCount > 0 ? qsTr("%1 waiting on you").arg(home.needsCount)
                                                  : qsTr("Nothing waiting on you")
                        color: Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.body
                    }
                }
                Item { Layout.fillWidth: true }
                ActionButton {
                    objectName: "startSomethingButton"
                    text: qsTr("Start something")
                    iconSource: MusterStyle.icon("plus")
                    iconColor: Theme.palette.background
                    variant: LogosButton.Variant.Primary
                    onClicked: home.newActivity()
                }
            }

            // ── getting started (exo-6e5): a short checklist that ticks itself off ──
            Surface {
                id: checklistSurface
                objectName: "homeChecklist"
                visible: home.checklistShown
                Layout.fillWidth: true
                implicitHeight: checklistCol.implicitHeight + 2 * Theme.spacing.large
                ColumnLayout {
                    id: checklistCol
                    anchors.fill: parent
                    anchors.margins: Theme.spacing.large
                    spacing: Theme.spacing.small
                    RowLayout {
                        Layout.fillWidth: true
                        LogosText {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            text: qsTr("Getting started")
                            color: Theme.palette.text
                            font.pixelSize: MusterStyle.subtitle
                            font.weight: Theme.typography.weightBold
                        }
                        ActionButton {
                            objectName: "homeChecklistHide"
                            quiet: true
                            compact: true
                            text: qsTr("Hide")
                            onClicked: firstRun.hidden = true
                        }
                    }
                    Repeater {
                        model: home.steps
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.spacing.medium
                            Rectangle {
                                implicitWidth: 18; implicitHeight: 18; radius: 9
                                color: modelData.done ? MusterStyle.settledSoft : "transparent"
                                border.width: modelData.done ? 0 : 1
                                border.color: Theme.palette.border
                                LogosText {
                                    textFormat: Text.PlainText
                                    anchors.centerIn: parent
                                    visible: modelData.done
                                    text: "✓"
                                    color: MusterStyle.settled
                                    font.pixelSize: MusterStyle.caption
                                    font.weight: Theme.typography.weightBold
                                }
                            }
                            LogosText {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: modelData.text
                                color: modelData.done ? Theme.palette.textTertiary : Theme.palette.text
                                font.pixelSize: MusterStyle.body
                                font.strikeout: modelData.done
                            }
                            ActionButton {
                                objectName: "homeStep_" + modelData.key
                                visible: !modelData.done && (modelData.key !== "share" || home.chatId.length > 0)
                                compact: true
                                text: modelData.action
                                onClicked: home.runStep(modelData.key)
                            }
                        }
                    }
                }
            }

            // ── setting up, when something waits on you (a fresh install, exo-d4d.6) ──
            // Muster never makes keys or chains: each step hands off to the app that owns it.
            // Asked only once an approval or a payment waits on you (exo-5a5); before that,
            // it is an optional step in the checklist above.
            InlineNotice {
                objectName: "homeSetup"
                visible: !!home.setup.show && (home.needsCount > 0 || home.setup.action !== "accounts")
                tone: "warning"
                title: String(home.setup.title || "")
                text: String(home.setup.detail || "")
                ActionButton {
                    objectName: "homeSetupAction"
                    compact: true
                    text: home.setup.action === "accounts" ? qsTr("Create or import an account")
                                                           : qsTr("Open Settings")
                    onClicked: home.setup.action === "accounts" ? home.manageAccounts() : home.openSettings()
                }
            }

            // ── invitations: someone opened a room with you; it reached your inbox ──
            ColumnLayout {
                Layout.fillWidth: true
                visible: (home.invites || []).length > 0
                spacing: Theme.spacing.small
                SectionHeader { text: qsTr("Invitations"); count: String((home.invites || []).length); hot: true }
                Repeater {
                    model: home.invites || []
                    delegate: Surface {
                        required property var modelData
                        tone: "needs"
                        Layout.fillWidth: true
                        implicitHeight: inviteRow.implicitHeight + 2 * Theme.spacing.medium
                        RowLayout {
                            id: inviteRow
                            anchors.fill: parent
                            anchors.margins: Theme.spacing.medium
                            spacing: Theme.spacing.medium
                            Avatar { identity: String(modelData.from || ""); name: String(modelData.fromAlias || "") }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                LogosText {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: {
                                        var who = String(modelData.fromAlias || "").length > 0
                                            ? String(modelData.fromAlias)
                                            : String(modelData.from || "someone").substring(0, 10) + "…";
                                        return who + qsTr(" invited you to a room");
                                    }
                                    color: Theme.palette.text
                                    font.pixelSize: MusterStyle.body
                                    font.weight: Theme.typography.weightBold
                                }
                                LogosText {
                                    textFormat: Text.PlainText
                                    visible: String(modelData.note || "").length > 0
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: String(modelData.note || "")
                                    color: Theme.palette.textSecondary
                                    font.pixelSize: MusterStyle.caption
                                }
                            }
                            ActionButton {
                                objectName: "joinInviteButton"
                                compact: true
                                text: qsTr("Join")
                                variant: LogosButton.Variant.Primary
                                onClicked: home.joinInvite(String(modelData.topic || ""))
                            }
                            ActionButton {
                                objectName: "dismissInviteButton"
                                compact: true
                                quiet: true
                                text: qsTr("Dismiss")
                                onClicked: home.dismissInvite(String(modelData.topic || ""))
                            }
                        }
                    }
                }
            }

            // ── the action list, grouped by what it asks of you ───────────────
            Repeater {
                objectName: "actionList"
                model: home.groups
                delegate: ColumnLayout {
                    id: group
                    required property var modelData
                    readonly property var rows: home.rowsIn(modelData.state)
                    visible: rows.length > 0
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    SectionHeader { text: group.modelData.title; count: String(group.rows.length); hot: group.modelData.hot }
                    Surface {
                        Layout.fillWidth: true
                        implicitHeight: rowsCol.implicitHeight + 2
                        ColumnLayout {
                            id: rowsCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 1
                            spacing: 0
                            Repeater {
                                model: group.rows
                                delegate: Rectangle {
                                    id: row
                                    required property var modelData
                                    required property int index
                                    objectName: "homeRow"
                                    Layout.fillWidth: true
                                    implicitHeight: rowBody.implicitHeight + 2 * Theme.spacing.medium
                                    color: rowHover.hovered ? Theme.palette.backgroundSecondary : "transparent"
                                    radius: Theme.spacing.radiusLarge
                                    Accessible.role: Accessible.Button
                                    Accessible.name: String(modelData.title || "") + ": " + String(modelData.action || "")
                                    Rectangle {
                                        visible: row.index > 0
                                        anchors.top: parent.top
                                        width: parent.width; height: 1
                                        color: Theme.palette.borderSubtle
                                    }
                                    RowLayout {
                                        id: rowBody
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.spacing.large
                                        anchors.rightMargin: Theme.spacing.medium
                                        spacing: Theme.spacing.medium
                                        Avatar { identity: String(row.modelData.topic || ""); name: String(row.modelData.title || ""); room: true }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
                                            LogosText {
                                                textFormat: Text.PlainText
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                                text: String(row.modelData.title || "")
                                                color: Theme.palette.text
                                                font.pixelSize: MusterStyle.body
                                                font.weight: Theme.typography.weightBold
                                            }
                                            LogosText {
                                                textFormat: Text.PlainText
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                                text: String(row.modelData.detail || "")
                                                visible: text.length > 0
                                                color: Theme.palette.textSecondary
                                                font.pixelSize: MusterStyle.caption
                                            }
                                        }
                                        StatusPill { text: String(row.modelData.action || ""); tone: home.tone(row.modelData.state) }
                                        LogosIcon {
                                            Layout.preferredWidth: 16; Layout.preferredHeight: 16
                                            source: MusterStyle.icon("chevron-right")
                                            color: Theme.palette.textTertiary
                                        }
                                    }
                                    HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: home.activated(String(row.modelData.topic || "")) }
                                }
                            }
                        }
                    }
                }
            }

            // Not yet known (exo-ba0): the rooms are on their way
            RowLayout {
                objectName: "homeLoading"
                visible: !home.loaded && (home.actions || []).length === 0
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.large
                spacing: Theme.spacing.medium
                Loading { running: parent.visible }
                LogosText {
                    textFormat: Text.PlainText
                    text: qsTr("Loading your rooms…")
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.body
                }
            }

            // Nothing on yet — the invitation to start, standing in for the list.
            EmptyState {
                objectName: "homeEmpty"
                // the checklist says the same while it shows
                visible: home.loaded && (home.actions || []).length === 0 && !home.checklistShown
                Layout.fillWidth: true
                text: qsTr("Nothing on yet. Start something with someone, or join a room with its code.")
            }

            // ── join with a room code (exo-dcc.28) ────────────────────────────
            // Someone shared a room's code: join it from here. Joining asks the room's
            // members to let you in.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.small
                spacing: Theme.spacing.small
                LogosText {
                    textFormat: Text.PlainText
                    text: qsTr("Have a room code?")
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.body
                }
                LogosTextField {
                    id: codeField
                    objectName: "homeRoomCodeField"
                    Layout.fillWidth: true
                    placeholderText: qsTr("/muster/1/muster.room.…/proto")
                }
                ActionButton {
                    objectName: "homeJoinCodeButton"
                    text: qsTr("Join")
                    enabled: codeField.text.trim().length > 0
                    onClicked: { home.joinCode(codeField.text.trim()); codeField.text = ""; }
                }
            }
        }
    }
}
