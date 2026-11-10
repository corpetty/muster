import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import Logos.Theme
import Logos.Controls
import Logos.Icons

// The room's header (exo-720.7, docs/design/ui-modernization.md §4 U3; reference
// ui/prototype/desktop-v3.html): one line, so the conversation owns the screen.
//   the room's name — click it to rename (the name is yours, kept on this device)
//   who is in it — their faces and a count, which open Room details › People
//   whether its connections are up — a dot, its popover the full list (invariant 8)
//   Invite — the room code, to copy
//   Room details — the drawer (RoomDetails), and ⋯ — Rename, Room history, Room map, Leave
// Until a room is joined, it is the join form. Every objectName the old header carried
// rides on the control that does the same job now (roomRenameButton and leaveRoomButton
// are menu items; roomTopicText and copyRoomTopic live in Invite).
ColumnLayout {
    id: header
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    Layout.fillWidth: true
    spacing: 0

    function startRename() { renameField.text = header.room.roomTitle; renameRow.open = true; renameField.textInput.forceActiveFocus(); }

    // the contacts not in this room yet, to invite with one click (exo-899)
    readonly property var invitable: {
        var cs = [];
        try { cs = JSON.parse(header.room.backend ? header.room.backend.contactsJson : "[]"); } catch (e) { cs = []; }
        var inRoom = {};
        for (var i = 0; i < header.room.members.length; ++i)
            inRoom[MusterStyle.personKey(header.room.members[i].identity)] = true;
        return cs.filter(function (c) {
            return c && /^(0x)?[0-9a-fA-F]{128}$/.test(String(c.identity || "")) && !inRoom[MusterStyle.personKey(c.identity)];
        });
    }
    function inviteById(id, name) {
        if (!header.room.backend || String(id).length === 0) return;
        header.room.backend.sendInvite(id, header.room.topic, "");
        header.room.backend.loadMembers();
        MusterStyle.notify(String(name || "").length > 0 ? qsTr("Invited %1").arg(name) : qsTr("Invited"));
    }

    // worst of the room's connections: down > warn > ok (the dot's colour)
    readonly property string connLevel: {
        var rows = (header.room.connectivity && header.room.connectivity.rows) || [];
        var lvl = "ok";
        for (var i = 0; i < rows.length; ++i) {
            var l = String(rows[i].level || "");
            if (l === "down" || l === "error") return "down";
            if (l !== "ok") lvl = "warn";
        }
        return rows.length > 0 ? lvl : "unknown";
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.preferredHeight: 56
        Layout.leftMargin: Theme.spacing.xlarge
        Layout.rightMargin: Theme.spacing.medium
        spacing: Theme.spacing.small

        // ── the name, or its rename field ────────────────────────────────
        LogosText {
            id: titleText
            objectName: "roomTitleText"
            visible: !renameRow.visible
            Layout.fillWidth: true
            text: header.room.joined || header.room.opening ? (header.room.roomTitle.length > 0 ? header.room.roomTitle : qsTr("Unnamed room"))
                                     : qsTr("Join a room")
            color: Theme.palette.text
            font.pixelSize: MusterStyle.subtitle
            font.weight: Theme.typography.weightBold
            elide: Text.ElideRight
            HoverHandler { id: titleHover; enabled: header.room.joined; cursorShape: Qt.PointingHandCursor }
            TapHandler { enabled: header.room.joined; onTapped: header.startRename() }
            LogosToolTip { visible: titleHover.hovered; text: qsTr("Rename (only you see the name)") }
        }
        RowLayout {
            id: renameRow
            property bool open: false
            visible: header.room.joined && open
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosTextField {
                id: renameField
                objectName: "roomRenameField"
                Layout.fillWidth: true
                placeholderText: qsTr("A name for this room (only you see it)")
                Keys.onEscapePressed: renameRow.open = false
            }
            Connections {
                target: renameField.textInput
                function onAccepted() { renameSave.clicked(); }
            }
            ActionButton {
                id: renameSave
                objectName: "roomRenameSave"
                text: qsTr("Save")
                variant: LogosButton.Variant.Primary
                onClicked: { header.room.renameRequested(header.room.topic, renameField.text); renameRow.open = false; }
            }
            ActionButton { text: qsTr("Cancel"); quiet: true; onClicked: renameRow.open = false }
        }

        // ── who is in it ─────────────────────────────────────────────────
        Rectangle {
            id: peopleButton
            visible: header.room.joined && !renameRow.visible
            implicitWidth: peopleRow.implicitWidth + 2 * Theme.spacing.small
            implicitHeight: 32
            radius: 16
            color: peopleHover.hovered ? Theme.palette.backgroundSecondary : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("%1 in the room — who can see this").arg(header.room.members.length)
            RowLayout {
                id: peopleRow
                anchors.centerIn: parent
                spacing: Theme.spacing.small
                Row {
                    spacing: -7
                    Repeater {
                        model: header.room.members.slice(0, 4)
                        delegate: Rectangle {
                            required property var modelData
                            width: 26; height: 26; radius: 13
                            color: Theme.palette.background
                            Avatar {
                                anchors.centerIn: parent
                                size: 22
                                identity: String(modelData.identity || "")
                                name: modelData.self ? "you" : String(modelData.alias || "")
                            }
                        }
                    }
                }
                LogosText {
                    objectName: "roomMembersLabel"
                    text: String(header.room.members.length)
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.body
                }
                Rectangle {      // someone asks to join
                    visible: header.room.pending.length > 0
                    implicitWidth: 8; implicitHeight: 8; radius: 4
                    color: MusterStyle.needs
                }
            }
            HoverHandler { id: peopleHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: header.room.openDetails("people") }
            LogosToolTip { visible: peopleHover.hovered; text: qsTr("Who is in the room") }
        }

        // ── its connections ──────────────────────────────────────────────
        Rectangle {
            id: connButton
            objectName: "roomConnections"
            visible: header.room.joined && !renameRow.visible
            implicitWidth: connRow.implicitWidth + 2 * Theme.spacing.medium
            implicitHeight: 28
            radius: 14
            color: connHover.hovered || connPop.opened ? Theme.palette.backgroundSecondary : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Connections: %1").arg(connWord.text)
            RowLayout {
                id: connRow
                anchors.centerIn: parent
                spacing: 6
                Rectangle {
                    implicitWidth: 7; implicitHeight: 7; radius: 4
                    color: header.connLevel === "ok" ? MusterStyle.settled
                         : header.connLevel === "down" ? MusterStyle.refused
                         : header.connLevel === "warn" ? MusterStyle.warning : Theme.palette.textMuted
                }
                LogosText {
                    id: connWord
                    text: header.connLevel === "ok" ? qsTr("live") : header.connLevel === "down" ? qsTr("down")
                        : header.connLevel === "warn" ? qsTr("degraded") : qsTr("checking…")
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                }
            }
            HoverHandler { id: connHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: connPop.opened ? connPop.close() : connPop.open() }
            Popup {
                id: connPop
                y: parent.height + 6
                x: parent.width - width
                width: 360
                padding: Theme.spacing.medium
                background: Surface { level: 2 }
                contentItem: ConnectionIndicators { status: header.room.connectivity }
            }
        }

        // ── Invite: the room code ────────────────────────────────────────
        ActionButton {
            id: inviteButton
            objectName: "roomInviteButton"
            visible: header.room.joined && !renameRow.visible
            text: qsTr("Invite")
            iconSource: MusterStyle.icon("link")
            onClicked: {
                if (invitePop.opened) { invitePop.close(); return; }
                if (header.room.backend) header.room.backend.loadContacts();
                invitePop.open();
            }
            Popup {
                id: invitePop
                y: parent.height + 6
                x: parent.width - width
                width: 400
                padding: Theme.spacing.large
                background: Surface { level: 2 }
                contentItem: ColumnLayout {
                    spacing: Theme.spacing.small
                    // ── invite someone by name or link (exo-899): they arrive a member ──
                    LogosText {
                        text: qsTr("Invite someone")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.body
                        font.weight: Theme.typography.weightBold
                    }
                    Flow {
                        Layout.fillWidth: true
                        visible: header.invitable.length > 0
                        spacing: Theme.spacing.small
                        Repeater {
                            model: header.invitable
                            delegate: ActionButton {
                                required property var modelData
                                objectName: "inviteContact_" + String(modelData.alias || "")
                                compact: true
                                text: String(modelData.alias || "")
                                onClicked: header.inviteById(String(modelData.identity || ""), String(modelData.alias || ""))
                            }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: inviteField
                            objectName: "inviteLinkField"
                            Layout.fillWidth: true
                            placeholderText: qsTr("or paste their contact link")
                        }
                        ActionButton {
                            objectName: "inviteSend"
                            text: qsTr("Invite")
                            variant: LogosButton.Variant.Primary
                            enabled: MusterStyle.parseContact(inviteField.text) !== null
                            onClicked: {
                                var c = MusterStyle.parseContact(inviteField.text);
                                if (c) header.inviteById(c.id, c.name);
                                inviteField.text = "";
                            }
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("They get it on their Home and join as a member: they read from then on, never what came before.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                    }
                    Rectangle { Layout.fillWidth: true; Layout.topMargin: Theme.spacing.small; implicitHeight: 1; color: Theme.palette.borderSubtle }
                    LogosText {
                        text: qsTr("Room code")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.body
                        font.weight: Theme.typography.weightBold
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        // exo-dcc.25: whoever joins with the code asks to join; a person you
                        // invite from "Start something" is let in by the invite itself
                        text: qsTr("Whoever joins with the code asks to join, and a member here decides.")
                        color: Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.caption
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: roomCode.implicitHeight + 2 * Theme.spacing.small
                            radius: Theme.spacing.radiusMedium
                            color: Theme.palette.backgroundInset
                            border.width: 1
                            border.color: Theme.palette.borderSubtle
                            // In full: the random tail is the part that names the room
                            TextEdit {
                                id: roomCode
                                objectName: "roomTopicText"
                                anchors.fill: parent
                                anchors.margins: Theme.spacing.small
                                readOnly: true
                                selectByMouse: true
                                wrapMode: TextEdit.WrapAnywhere
                                text: header.room.topic
                                color: Theme.palette.text
                                selectionColor: Theme.palette.primary
                                font.family: MusterStyle.mono
                                font.pixelSize: MusterStyle.caption
                            }
                        }
                        ActionButton {
                            id: copyCode
                            objectName: "copyRoomTopic"
                            property bool copied: false
                            text: copied ? qsTr("Copied") : qsTr("Copy")
                            iconSource: LogosIcons.copy
                            onClicked: { roomCode.selectAll(); roomCode.copy(); roomCode.deselect(); copied = true; copiedReset.restart(); }
                            Timer { id: copiedReset; interval: 2000; onTriggered: copyCode.copied = false }
                        }
                    }
                }
            }
        }

        // ── the details drawer, and ⋯ ────────────────────────────────────
        IconAction {
            objectName: "roomDetailsToggle"
            visible: header.room.joined && !renameRow.visible
            label: header.room.detailsOpen ? qsTr("Hide room details") : qsTr("Room details")
            icon: MusterStyle.icon("details-panel")
            checked: header.room.detailsOpen
            onClicked: header.room.detailsOpen ? header.room.closeDetails() : header.room.openDetails(header.room.detailsTab)
        }
        IconAction {
            id: moreButton
            objectName: "roomMoreButton"
            visible: header.room.joined && !renameRow.visible
            label: qsTr("More")
            icon: LogosIcons.more
            onClicked: moreMenu.popup(moreButton, moreButton.width - moreMenu.width, moreButton.height + 4)
            LogosMenu {
                id: moreMenu
                LogosMenuItem { objectName: "roomRenameButton"; text: qsTr("Rename"); onTriggered: header.startRename() }
                LogosMenuItem { text: qsTr("Room details"); onTriggered: header.room.openDetails("people") }
                LogosMenuItem { text: qsTr("Room history"); onTriggered: header.room.openDetails("history") }
                LogosMenuItem { objectName: "roomFileShareButton"; text: qsTr("FileShare"); onTriggered: header.room.openDetails("files") }
                LogosMenuItem { objectName: "roomQuestsButton"; text: qsTr("Quests"); onTriggered: header.room.openDetails("quests") }
                LogosMenuItem { objectName: "roomMapButton"; text: qsTr("Room map"); onTriggered: header.room.openMap("room", "") }
                LogosMenuSeparator {}
                LogosMenuItem { objectName: "leaveRoomButton"; text: qsTr("Leave room…"); onTriggered: leaveConfirm.open() }
            }
        }
    }

    // ── join (until a room is joined) ─────────────────────────────────────
    RowLayout {
        visible: !header.room.joined && !header.room.opening
        Layout.fillWidth: true
        Layout.leftMargin: Theme.spacing.xlarge
        Layout.rightMargin: Theme.spacing.xlarge
        Layout.bottomMargin: Theme.spacing.medium
        spacing: Theme.spacing.small
        LogosTextField {
            id: topicField
            objectName: "roomTopicField"
            Layout.fillWidth: true
            placeholderText: qsTr("room code, e.g. /muster/1/muster.room.6ac8ea9cdc366149/proto")
        }
        ActionButton {
            objectName: "joinRoomButton"
            text: qsTr("Join")
            variant: LogosButton.Variant.Primary
            enabled: topicField.text.length > 0
            onClicked: {
                header.room.founded = false;   // joined by name: maybe someone else's room
                if (header.room.backend) header.room.backend.joinRoom(topicField.text);
            }
        }
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }

    // ── leaving: say what it does before doing it (exo-dcc.28) ─────────────
    Popup {
        id: leaveConfirm
        objectName: "leaveConfirm"
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        width: Math.min(440, parent ? parent.width - 32 : 440)
        padding: Theme.spacing.xlarge
        background: Surface { level: 2 }
        contentItem: ColumnLayout {
            spacing: Theme.spacing.medium
            LogosText {
                text: qsTr("Leave this room?")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.subtitle
                font.weight: Theme.typography.weightBold
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("It stops showing here, and this device stops following it. "
                           + "The others are not told and still count you in. Join it again with its room code.")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.body
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: Theme.spacing.small
                ActionButton { text: qsTr("Stay"); quiet: true; onClicked: leaveConfirm.close() }
                ActionButton {
                    objectName: "leaveRoomConfirm"
                    text: qsTr("Leave room")
                    variant: LogosButton.Variant.Primary
                    onClicked: { leaveConfirm.close(); header.room.leaveRequested(header.room.topic); }
                }
            }
        }
    }
}
