import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// This account's own card: its short identity, its connectivity, and the full
// address with a one-tap copy, so what a peer needs to reach you is on screen
// rather than behind an action. Set the properties; standalone.
Rectangle {
    id: root

    // This account's own address. Empty until the backend is online, which
    // leaves the card showing the connection state alone.
    required property string address
    // Short form of the address, the card's headline identity.
    required property string label
    // Two-letter form of the address, for the avatar.
    required property string initials
    required property bool online
    // Short connectivity label ("Online", "Initialising...").
    required property string statusLabel

    // True briefly after a copy, so the tooltip can confirm it.
    readonly property bool copiedFlashing: copiedTimer.running

    implicitWidth: 260
    implicitHeight: layout.implicitHeight + 2 * Theme.spacing.medium
    radius: Theme.spacing.radiusXlarge
    color: Theme.palette.backgroundTertiary
    border.width: 1
    border.color: Theme.palette.borderSubtle

    ClipboardProxy {
        id: clipboard
    }

    Timer {
        id: copiedTimer
        interval: 2000
    }

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            Avatar {
                // The ramp is unused for this account, which takes the brand one.
                ramp: 0
                isSelf: true
                initials: root.initials
                showPresence: true
                online: root.online
                Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                LogosText {
                    objectName: "myLabelText"
                    visible: root.label !== ""
                    text: root.label
                    textFormat: Text.PlainText
                    color: Theme.palette.text
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                LogosText {
                    text: root.statusLabel
                    textFormat: Text.PlainText
                    color: root.online ? ChatTheme.settled : Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightMedium
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }

        // The address gets a field's surface rather than a label's, because it
        // is a value to be taken rather than a line to be read.
        Rectangle {
            visible: root.address !== ""
            Layout.fillWidth: true
            implicitHeight: 28
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.backgroundMuted
            border.width: 1
            border.color: Theme.palette.borderSubtle

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.spacing.small
                anchors.rightMargin: Theme.spacing.tiny
                spacing: Theme.spacing.tiny

                // The confirmation lands on the value itself, so a copy reads
                // as done without hovering anything.
                LogosText {
                    objectName: "myAddressText"
                    text: root.copiedFlashing ? qsTr("Copied to clipboard") : root.address
                    textFormat: Text.PlainText
                    color: root.copiedFlashing ? ChatTheme.settled : Theme.palette.textTertiary
                    font.family: root.copiedFlashing ? Theme.typography.publicSans : Theme.typography.mono
                    font.pixelSize: Theme.typography.secondaryText
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }

                ChatIconButton {
                    id: copyButton
                    objectName: "copyMyAddressButton"
                    size: 24
                    iconSize: 12
                    iconSource: Qt.resolvedUrl("icons/copy.png")
                    Accessible.role: Accessible.Button
                    Accessible.name: qsTr("Copy my address")
                    onClicked: {
                        clipboard.copy(root.address);
                        copiedTimer.restart();
                    }
                    Layout.alignment: Qt.AlignVCenter

                    LogosToolTip {
                        text: qsTr("Copy my address")
                        placement: LogosToolTip.Top
                        visible: copyButton.hovered
                    }
                }
            }
        }
    }
}
