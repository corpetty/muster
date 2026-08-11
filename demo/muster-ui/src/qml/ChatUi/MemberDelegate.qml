import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A roster row: the member's avatar and identity, marked as this account where
// it is, and told as waiting where the invitation has not committed yet. A
// right-click asks for the row's actions; Return copies from the keyboard.
// Delegate roles bind by name.
LogosItemDelegate {
    id: root

    required property string label
    required property string address
    // Avatar identity, computed by the model from the address.
    required property string avatarInitials
    required property int avatarRamp
    required property bool isSelf
    // Invited but not yet committed into the group's roster.
    required property bool pending

    // Asks for the row's actions, carrying the address they act on.
    signal contextMenuRequested(string address)

    // True briefly after a copy, so the row can confirm it.
    readonly property bool copiedFlashing: copiedTimer.running

    width: 200
    implicitHeight: 56
    radius: Theme.spacing.radiusMedium
    leftPadding: Theme.spacing.small
    rightPadding: Theme.spacing.small
    hoverColor: Theme.palette.overlayLight

    Accessible.role: Accessible.ListItem
    Accessible.name: label

    // Flash a brief confirmation that the address was copied.
    function flashCopied() {
        copiedTimer.restart();
    }

    Timer {
        id: copiedTimer
        interval: 1500
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: if (root.address !== "")
            root.contextMenuRequested(root.address)
    }

    contentItem: RowLayout {
        spacing: Theme.spacing.small

        Avatar {
            initials: root.avatarInitials
            ramp: root.avatarRamp
            isSelf: root.isSelf
            size: 32
            // A member who has not joined yet is drawn back, so the roster reads
            // as the people actually in the group.
            opacity: root.pending ? 0.5 : 1
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            LogosText {
                text: root.copiedFlashing ? qsTr("Copied to clipboard") : root.label
                textFormat: Text.PlainText
                color: root.copiedFlashing ? ChatTheme.settled : root.pending ? Theme.palette.textTertiary : Theme.palette.text
                font.family: root.copiedFlashing ? Theme.typography.publicSans : Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            RowLayout {
                visible: root.pending
                spacing: Theme.spacing.tiny

                LogosSpinner {
                    running: root.pending
                    ringColor: Theme.palette.border
                    thickness: 2
                    dotSize: 4
                    Layout.preferredWidth: 10
                    Layout.preferredHeight: 10
                    Layout.alignment: Qt.AlignVCenter
                }

                LogosText {
                    //: Said of a member who has been invited but has not joined yet
                    text: qsTr("Waiting to join")
                    color: Theme.palette.warning
                    font.pixelSize: Theme.typography.secondaryText
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }

        LogosBadge {
            visible: root.isSelf
            //: Badge marking the current user in the member list
            text: qsTr("you")
            color: Theme.palette.backgroundBlack
            backgroundColor: ChatTheme.signal
            borderColor: ChatTheme.signal
            radius: Theme.spacing.radiusPill
            Layout.alignment: Qt.AlignVCenter
        }
    }

    LogosToolTip {
        text: root.address
        placement: LogosToolTip.Left
        visible: root.hovered && !root.pending && root.address !== ""
    }
}
