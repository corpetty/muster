import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Starting something: what you want to do, then who with, then which account
// does it.
//
// That order is the app's whole argument, so it is the order the composer asks
// in. A chat app would ask "one person or a group?" first, which makes the
// user pick a container before they have said what it is for. Here the verb
// comes first and everything after it is scoped by that choice — the account
// list is filtered by what the activity needs, and the room opens knowing what
// it is for rather than as an empty thread someone has to explain to.
//
// The button never says "OK". It says which choice is still missing, so the
// gate is legible instead of a disabled control you have to poke at.
LogosDialog {
    id: root

    // What the wallet can offer: every holding it has, from the backend's
    // catalogue. Which one a payment draws on is decided later, at the address,
    // because that is where the destination — and so the set of rails that can
    // reach it — is actually known.
    property bool walletReady: false
    property var assets: []

    // verb: "pay" | "request" | "talk"
    signal activityChosen(string verb, string peerAddress)

    title: qsTr("Start something")
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    anchors.centerIn: Overlay.overlay
    width: Math.min(520, (Overlay.overlay ? Overlay.overlay.width : 520) - 2 * Theme.spacing.large)

    property string verb: ""
    readonly property string peerAddress: addressField.text.trim()
    // One account in this build, so it is pre-picked once the wallet is open —
    // but the step still exists, because which account acts is a real question
    // and pretending otherwise would teach the wrong shape.
    readonly property bool accountReady: root.walletReady

    // Names the next missing choice rather than going flat and silent.
    readonly property string gateLabel: {
        if (root.verb === "")
            return qsTr("Pick an activity");
        if (root.verb !== "talk" && !root.accountReady)
            return qsTr("Open your wallet first");
        if (root.peerAddress === "")
            return qsTr("Add someone");
        return qsTr("Open the room");
    }
    readonly property bool ready: root.gateLabel === qsTr("Open the room")

    onOpened: {
        root.verb = "";
        addressField.text = "";
    }

    leftActions: [
        LogosButton {
            implicitWidth: 96
            implicitHeight: 36
            text: qsTr("Cancel")
            onClicked: root.close()
        }
    ]
    rightActions: [
        LogosButton {
            objectName: "openRoomButton"
            implicitWidth: 180
            implicitHeight: 36
            text: root.gateLabel
            enabled: root.ready
            onClicked: {
                if (!root.ready)
                    return;
                root.activityChosen(root.verb, root.peerAddress);
                root.close();
            }
        }
    ]

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium

        // ── 1. what ──────────────────────────────────────────────────────
        LogosText {
            text: qsTr("WHAT DO YOU WANT TO DO")
            color: Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
            font.weight: Theme.typography.weightMedium
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            Repeater {
                model: [
                    { id: "pay", name: qsTr("Pay someone"),
                      note: qsTr("You send. Their address stays in the room.") },
                    { id: "request", name: qsTr("Ask to be paid"),
                      note: qsTr("They send. Yours does.") },
                    { id: "talk", name: qsTr("Just talk"),
                      note: qsTr("No money, same room.") }
                ]

                delegate: Rectangle {
                    required property var modelData
                    readonly property bool picked: root.verb === modelData.id

                    Layout.fillWidth: true
                    implicitHeight: verbCol.implicitHeight + 2 * Theme.spacing.small
                    radius: Theme.spacing.radiusMedium
                    color: picked ? Theme.palette.surfaceRaised : Theme.palette.surfaceRecessed
                    border.width: 1
                    border.color: picked ? ChatTheme.signal : Theme.palette.borderSubtle

                    TapHandler {
                        onTapped: root.verb = modelData.id
                    }

                    ColumnLayout {
                        id: verbCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacing.small
                        spacing: 1

                        LogosText {
                            text: modelData.name
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.primaryText
                            font.weight: Theme.typography.weightMedium
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: modelData.note
                            color: Theme.palette.textTertiary
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }
                }
            }
        }

        // ── 2. who ───────────────────────────────────────────────────────
        LogosText {
            visible: root.verb !== ""
            text: qsTr("WHO WITH")
            color: Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
            font.weight: Theme.typography.weightMedium
        }

        LogosTextField {
            id: addressField
            objectName: "activityAddressField"
            visible: root.verb !== ""
            Layout.fillWidth: true
            placeholderText: qsTr("paste their address")
            font.family: Theme.typography.mono
            Keys.onReturnPressed: function (event) {
                if (root.ready) {
                    root.activityChosen(root.verb, root.peerAddress);
                    root.close();
                }
                event.accepted = true;
            }
        }

        // ── 3. which account ─────────────────────────────────────────────
        LogosText {
            visible: root.verb !== "" && root.verb !== "talk"
            text: qsTr("PAID FROM")
            color: Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
            font.weight: Theme.typography.weightMedium
        }

        Rectangle {
            visible: root.verb !== "" && root.verb !== "talk"
            Layout.fillWidth: true
            implicitHeight: acctCol.implicitHeight + 2 * Theme.spacing.small
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surfaceRecessed
            border.width: 1
            border.color: root.accountReady ? ChatTheme.signal : Theme.palette.borderSubtle

            ColumnLayout {
                id: acctCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.small
                spacing: 1

                LogosText {
                    text: qsTr("Your accounts")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightMedium
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    // Every holding, named and counted, rather than the one
                    // this build used to be able to pay from. Which of them a
                    // payment draws on is chosen at the address, with the rail.
                    text: root.accountReady
                        ? root.assets.map(a => qsTr("%1 %2")
                            .arg(a.balance === "" ? "—" : a.balance).arg(a.name)).join(" · ")
                        : qsTr("No wallet open yet. Open one from the sidebar and this becomes available.")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }
            }
        }

        // The running scope claim, updated as choices are made — nothing has
        // been shared yet, and saying so is worth a line.
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.verb === ""
                ? qsTr("Nothing is shared until the room opens.")
                : root.peerAddress === ""
                    ? qsTr("Nothing is shared until the room opens. Their address never leaves your machine to find them — you already have it.")
                    : qsTr("2 people will be able to read this room. Nobody else.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
        }
    }
}
