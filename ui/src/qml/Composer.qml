import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// F-18 — create a room from an action. The composer asks in the order the app
// argues in: what you want to do, then who with, then which account does it.
// The verb comes first because everything after it is scoped by that choice; a
// chat app asks "one person or a group?" first and makes you pick a container
// before you have said what it is for.
//
// PURE-RENDER: this view calls no backend. It emits createRoom(verb, peer,
// topic) when the user confirms and lets the host wire that to the module. The
// topic is derived here so the room opens knowing what it is for.
//
// NB (ADR-011): nix build does not evaluate QML — a QML error blanks the whole
// view and is invisible to the build. This restricts itself to Theme keys and
// the Logos.Controls types Main.qml already uses (LogosText, LogosButton,
// LogosTextField); everything is guarded.
Item {
    id: composer

    // Fired when the user confirms. The host opens the room from these — and sets it
    // to coordinate under `policy` (the driver the intent runs on).
    signal createRoom(string verb, string peer, string topic, string policy)

    // "" until a verb tile is picked. Drives the progressive reveal.
    property string pickedVerb: ""
    // The coordination policy (driver) the room will run under. Chosen at compose
    // time — the account/policy is a dependency of the intent.
    property string pickedPolicy: "safe"

    readonly property var verbs: [
        { id: "pay",     name: qsTr("Pay someone"),
          note: qsTr("You send. Their address stays in the room.") },
        { id: "request", name: qsTr("Ask to be paid"),
          note: qsTr("They send. Yours stays in the room.") },
        { id: "split",   name: qsTr("Split a cost"),
          note: qsTr("Shared bill, one room, everyone sees the same thing.") },
        { id: "talk",    name: qsTr("Just talk"),
          note: qsTr("No money, same room.") }
    ]

    readonly property string peer: peerField ? peerField.text.trim() : ""
    readonly property bool hasVerb: composer.pickedVerb.length > 0
    readonly property bool hasPeer: composer.peer.length > 0
    readonly property int scopeCount: 1 + (composer.hasPeer ? 1 : 0)

    // "muster." + verb + "." + a short suffix off the peer, or just the verb solo.
    function derivedTopic() {
        if (!composer.hasVerb)
            return "";
        if (composer.hasPeer) {
            var bare = composer.peer.replace(/^0x/i, "");
            var suffix = bare.substring(Math.max(0, bare.length - 6)).toLowerCase();
            if (suffix.length === 0)
                suffix = "room";
            return "muster." + composer.pickedVerb + "." + suffix;
        }
        return "muster." + composer.pickedVerb;
    }

    // The button names the next missing choice rather than going flat and silent.
    readonly property string confirmLabel: {
        if (!composer.hasVerb)
            return qsTr("Pick an activity");
        if (composer.hasPeer)
            return qsTr("Open the room with them");
        return qsTr("Open the room — just you");
    }

    function confirm() {
        if (!composer.hasVerb)
            return;
        composer.createRoom(composer.pickedVerb, composer.peer,
                            composer.derivedTopic(), composer.pickedPolicy);
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: stack.implicitHeight + 2 * Theme.spacing.xlarge
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: stack
            y: Theme.spacing.xlarge
            x: (flick.width - width) / 2
            width: Math.min(flick.width - 2 * Theme.spacing.xlarge, 560)
            spacing: Theme.spacing.large

            LogosText {
                text: qsTr("Start something")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
            }

            // ── 1. what ───────────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("What do you want to do?")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightBold
                }

                Repeater {
                    model: composer.verbs

                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool picked: composer.pickedVerb === modelData.id

                        Layout.fillWidth: true
                        implicitHeight: verbCol.implicitHeight + 2 * Theme.spacing.medium
                        radius: Theme.spacing.radiusMedium
                        color: picked ? Theme.palette.surfaceRaised : Theme.palette.surface
                        border.width: 1
                        border.color: picked ? Theme.palette.borderDefault : Theme.palette.borderSubtle

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: composer.pickedVerb = modelData.id
                        }

                        ColumnLayout {
                            id: verbCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            LogosText {
                                text: modelData.name
                                color: Theme.palette.text
                                font.family: Theme.typography.publicSans
                                font.pixelSize: Theme.typography.primaryText
                                font.weight: Theme.typography.weightMedium
                            }
                            LogosText {
                                Layout.fillWidth: true
                                text: modelData.note
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
            }

            // ── 2. who ────────────────────────────────────────────────────────
            ColumnLayout {
                visible: composer.hasVerb
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("Who's doing it with you?")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightBold
                }

                LogosTextField {
                    id: peerField
                    objectName: "composerPeerField"
                    Layout.fillWidth: true
                    placeholderText: qsTr("paste their address (leave empty for just you)")
                }

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Only these people can read the room. Add someone later and they see the thread from that point forward.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                    wrapMode: Text.WordWrap
                }
            }

            // ── 3. which policy (the account/driver the intent runs on) ───────
            ColumnLayout {
                visible: composer.hasVerb
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("How does the room approve?")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightBold
                }

                Repeater {
                    model: [
                        { id: "safe",      name: qsTr("Safe · 2 of 3"),
                          note: qsTr("EIP-712 multisig — owners sign on-chain-bound transactions.") },
                        { id: "threshold", name: qsTr("Threshold · 2 of 3"),
                          note: qsTr("k-of-n endorsement — the group signs off, no chain required.") }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool picked: composer.pickedPolicy === modelData.id

                        Layout.fillWidth: true
                        implicitHeight: polCol.implicitHeight + 2 * Theme.spacing.medium
                        radius: Theme.spacing.radiusMedium
                        color: picked ? Theme.palette.surfaceRaised : Theme.palette.surface
                        border.width: 1
                        border.color: picked ? Theme.palette.borderDefault : Theme.palette.borderSubtle

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: composer.pickedPolicy = modelData.id
                        }

                        ColumnLayout {
                            id: polCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            LogosText {
                                text: modelData.name
                                color: Theme.palette.text
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.primaryText
                                font.weight: Theme.typography.weightMedium
                            }
                            LogosText {
                                Layout.fillWidth: true
                                text: modelData.note
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("The policy is the driver the room runs on — you can change it in the room. "
                             + "The conversation looks the same either way.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                    wrapMode: Text.WordWrap
                }
            }

            // ── footer ────────────────────────────────────────────────────────
            LogosText {
                Layout.fillWidth: true
                text: qsTr("%1 people can read this. Nobody else.").arg(composer.scopeCount)
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                wrapMode: Text.WordWrap
            }

            LogosButton {
                objectName: "openRoomButton"
                Layout.fillWidth: true
                text: composer.confirmLabel
                enabled: composer.hasVerb
                onClicked: composer.confirm()
            }
        }
    }
}
