import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls
import Logos.Icons

// The app's sidebar (exo-720.6, docs/design/ui-modernization.md §4 U2): what waits on you,
// your rooms, and the rest of the app, where every chat client keeps them. It replaces the
// top bar of seven buttons. Reference: ui/prototype/desktop-v3.html.
//
// Three modes, chosen by Main from the width and your preference:
//   full    248 px, labels and each room's last line
//   rail     60 px, icons and room avatars, each labelled by its tooltip. Inside Basecamp,
//            whose own sidebar sits beside this one, it starts here (decision §6.1).
//   drawer  off-canvas below 900 px; Main's top strip opens it
//
// It reads Main's state (`app`) and changes only `app.view` and the active room, through
// app.enterRoom: the same paths the old nav bar took. The old buttons' objectNames ride on
// the rows that do their job, so the UI harness (ui/tests/muster-ui-test.mjs) still finds
// them: homeToggle, roomToggle, dashboardToggle, contactsToggle, walkthroughToggle,
// settingsToggle (lezToggle is the Wallet's Send on LEZ tab now).
Rectangle {
    id: side

    required property var app            // Main.qml's root
    property string mode: "full"
    readonly property bool rail: mode === "rail"
    signal collapseToggled()
    signal closeRequested()
    signal jumpRequested()      // Ctrl+K's room switcher (RoomSwitcher)

    implicitWidth: rail ? 60 : mode === "drawer" ? 272 : 248
    color: Theme.palette.backgroundTertiary

    // what waits on you: each intent the module classed as needing you, in every joined
    // room (F-18, exo-ed5), and each room invitation not yet answered
    readonly property var invites: {
        try { return JSON.parse(side.app.backend ? side.app.backend.invitesJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property int needsCount: {
        var n = side.invites.length;
        var convs = side.app.conversations || [];
        for (var i = 0; i < convs.length; ++i)
            n += Array.isArray(convs[i].needs) ? convs[i].needs.length : 0;
        return n;
    }
    function go(view) {
        side.app.view = view;
        if (side.mode === "drawer") side.closeRequested();
    }
    function roomDetail(c) {
        // not Array.isArray: through a Repeater's modelData the array is a Qt list
        var ns = (c.needs && c.needs.length > 0) ? c.needs : [];
        if (ns.length > 0) return side.app.needsHeadline(String(ns[0].what || ""));
        if (Number(c.waiting || 0) > 0) return qsTr("Waiting on others");
        if (Number(c.settled || 0) > 0) return qsTr("Done");
        return qsTr("Nothing waits on you");
    }

    Rectangle {      // the edge against the content
        anchors.right: parent.right
        width: 1; height: parent.height
        color: Theme.palette.borderSubtle
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.rightMargin: 1
        spacing: 0

        // ── brand, and collapse / close ──────────────────────────────────
        GridLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.medium
            Layout.leftMargin: side.rail ? 0 : Theme.spacing.large
            Layout.rightMargin: side.rail ? 0 : Theme.spacing.small
            Layout.bottomMargin: Theme.spacing.small
            columns: side.rail ? 1 : 3
            rowSpacing: Theme.spacing.small
            columnSpacing: Theme.spacing.small
            Rectangle {
                Layout.alignment: side.rail ? Qt.AlignHCenter : Qt.AlignVCenter
                implicitWidth: 24; implicitHeight: 24
                radius: Theme.spacing.radiusMedium
                color: Theme.palette.primary
                LogosText {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "M"
                    color: Theme.palette.background
                    font.pixelSize: 13
                    font.weight: Theme.typography.weightBold
                }
            }
            LogosText {
                textFormat: Text.PlainText
                visible: !side.rail
                Layout.fillWidth: true
                text: qsTr("Muster")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.subtitle
                font.weight: Theme.typography.weightBold
            }
            IconAction {
                objectName: "sidebarCollapse"
                Layout.alignment: side.rail ? Qt.AlignHCenter : Qt.AlignVCenter
                label: side.mode === "drawer" ? qsTr("Close the sidebar")
                     : side.rail ? qsTr("Expand the sidebar") : qsTr("Collapse the sidebar")
                icon: side.mode === "drawer" ? LogosIcons.close : MusterStyle.icon("sidebar")
                onClicked: side.mode === "drawer" ? side.closeRequested() : side.collapseToggled()
            }
        }

        // ── what waits on you, and your rooms ────────────────────────────
        Flickable {
            id: scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: list.implicitHeight + Theme.spacing.small
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: list
                x: side.rail ? Theme.spacing.small : Theme.spacing.small
                width: scroller.width - 2 * Theme.spacing.small
                spacing: 2

                SidebarRow {
                    objectName: "sidebarJump"
                    label: qsTr("Jump to…  Ctrl K")
                    icon: LogosIcons.search
                    rail: side.rail
                    onClicked: side.jumpRequested()
                }
                SidebarRow {
                    objectName: "homeToggle"
                    label: qsTr("Needs you")
                    icon: MusterStyle.icon("inbox")
                    count: side.needsCount
                    rail: side.rail
                    // Compose is a step of Home ("Start something"), so Home stays lit through it
                    current: side.app.view === "home" || side.app.view === "compose"
                    onClicked: {
                        side.go("home");
                        if (side.app.backend) side.app.backend.loadConversations();
                    }
                }

                SectionHeader {
                    visible: !side.rail
                    Layout.topMargin: Theme.spacing.large
                    Layout.leftMargin: Theme.spacing.small
                    Layout.bottomMargin: 2
                    text: qsTr("Rooms")
                    IconAction {
                        objectName: "sidebarNewRoom"
                        label: qsTr("Start something")
                        icon: MusterStyle.icon("plus")
                        size: 24
                        onClicked: { side.go("compose"); if (side.app.backend) side.app.backend.loadContacts(); }
                    }
                }
                Rectangle {      // in the rail, a rule stands for the header
                    visible: side.rail
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.small
                    Layout.bottomMargin: Theme.spacing.small
                    implicitHeight: 1
                    color: Theme.palette.borderSubtle
                }
                IconAction {
                    visible: side.rail
                    Layout.alignment: Qt.AlignHCenter
                    label: qsTr("Start something")
                    icon: MusterStyle.icon("plus")
                    onClicked: { side.go("compose"); if (side.app.backend) side.app.backend.loadContacts(); }
                }

                Repeater {
                    model: side.app.conversations || []
                    delegate: SidebarRow {
                        required property var modelData
                        readonly property string topic: String(modelData.topic || "")
                        readonly property bool active: topic.length > 0 && topic === side.app.roomTopic
                        // the old Room button showed the active room: its job is this row's now
                        objectName: active ? "roomToggle" : "sidebarRoom"
                        label: side.app.titleOf(topic) || side.app.shortRoom(topic)
                        detail: side.roomDetail(modelData)
                        detailHot: !!(modelData.needs && modelData.needs.length > 0)
                        needs: detailHot
                        unread: side.app.isUnread(modelData)
                        avatarId: topic
                        rail: side.rail
                        current: side.app.view === "room" && active
                        onClicked: { side.app.enterRoom(topic); if (side.mode === "drawer") side.closeRequested(); }
                    }
                }

                SidebarRow {
                    // with no room open, this is where the old Room button led: the join form
                    objectName: side.app.roomTopic.length === 0 ? "roomToggle" : "sidebarJoinCode"
                    label: qsTr("Join with a room code")
                    icon: MusterStyle.icon("link")
                    rail: side.rail
                    current: side.app.view === "room" && side.app.roomTopic.length === 0
                    onClicked: side.go(side.app.roomTopic.length === 0 ? "room" : "home")
                }
            }
        }

        // ── the rest of the app ──────────────────────────────────────────
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.spacing.small
            spacing: 2
            SidebarRow {
                objectName: "dashboardToggle"
                label: qsTr("Wallet")
                icon: MusterStyle.icon("wallet")
                rail: side.rail
                current: side.app.view === "dashboard" || side.app.view === "lez"
                onClicked: {
                    side.go("dashboard");
                    // re-read on entry, so the card recovers if the read at startup came too early
                    side.app.refreshBalances();
                }
            }
            SidebarRow {
                objectName: "contactsToggle"
                label: qsTr("Contacts")
                icon: MusterStyle.icon("people")
                rail: side.rail
                current: side.app.view === "contacts"
                onClicked: { side.go("contacts"); if (side.app.backend) side.app.backend.loadContacts(); }
            }
            SidebarRow {
                objectName: "walkthroughToggle"
                label: qsTr("Learn")
                icon: MusterStyle.icon("book")
                rail: side.rail
                current: side.app.view === "walkthrough"
                onClicked: side.go(side.app.view === "walkthrough" ? "home" : "walkthrough")
            }
            SidebarRow {
                objectName: "settingsToggle"
                label: qsTr("Settings")
                icon: MusterStyle.icon("gear")
                rail: side.rail
                current: side.app.view === "settings"
                onClicked: { side.go("settings"); if (side.app.backend) side.app.backend.loadSettings(); }
            }
            // who you are here: your room identity, as the others see its id (your own alias
            // for yourself is not something the room knows)
            SidebarRow {
                objectName: "sidebarIdentity"
                readonly property string me: {
                    // ed25519 then x25519: the room identity as the member list carries it, so
                    // your face here is the one the room shows
                    try {
                        var id = (JSON.parse(side.app.backend ? side.app.backend.settingsJson : "{}").identity) || {};
                        return String(id.ed25519 || "") + String(id.x25519 || "");
                    } catch (e) { return ""; }
                }
                visible: me.length > 0
                Layout.topMargin: Theme.spacing.tiny
                label: qsTr("You")
                detail: me.length > 12 ? me.slice(0, 6) + "…" + me.slice(-4) : me
                avatarId: me
                avatarName: "you"
                avatarIsRoom: false
                rail: side.rail
                onClicked: { side.go("settings"); if (side.app.backend) side.app.backend.loadSettings(); }
            }
        }
    }
}
