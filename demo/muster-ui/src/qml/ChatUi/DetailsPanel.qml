import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What the conversation is, beyond its name: its full description and the facts
// a header has no room for, each copyable where copying it is useful. Shown on
// demand from the thread header, so it costs the layout nothing while it is
// closed. Set the properties and connect closeRequested; standalone.
Rectangle {
    id: root

    required property bool isGroup
    // The group's shared description; empty for a direct conversation.
    property string description: ""
    required property string conversationId
    // The other participant's address in a direct conversation, empty while
    // unknown or for a group.
    property string peerAddress: ""
    property int memberCount: 0
    // Members invited but not yet on the roster.
    property int pendingMemberCount: 0

    signal closeRequested

    // The roster's size with outstanding invitations named separately: an
    // invited member does not count towards the group until they join.
    readonly property string memberSummary: {
        const joined = root.memberCount === 1 ? qsTr("1 joined") : qsTr("%1 joined").arg(root.memberCount);
        if (root.pendingMemberCount === 0)
            return joined;
        const invited = root.pendingMemberCount === 1 ? qsTr("1 invited") : qsTr("%1 invited").arg(root.pendingMemberCount);
        return qsTr("%1, %2").arg(joined).arg(invited);
    }

    implicitWidth: 280
    implicitHeight: layout.implicitHeight + 2 * Theme.spacing.medium
    radius: Theme.spacing.radiusXlarge
    color: Theme.palette.backgroundTertiary
    border.width: 1
    border.color: Theme.palette.borderSubtle

    ClipboardProxy {
        id: clipboard
    }

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.topMargin: Theme.spacing.medium
        anchors.bottomMargin: Theme.spacing.medium
        anchors.leftMargin: Theme.spacing.large
        anchors.rightMargin: Theme.spacing.large
        spacing: 0

        PanelHeader {
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.spacing.small
            //: Header of the panel carrying the conversation's facts
            title: qsTr("Details")

            ChatIconButton {
                id: closeButton
                objectName: "closeDetailsButton"
                size: 24
                iconSize: 12
                iconSource: Qt.resolvedUrl("icons/close.png")
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Close details")
                onClicked: root.closeRequested()

                LogosToolTip {
                    text: qsTr("Close")
                    placement: LogosToolTip.Left
                    visible: closeButton.hovered
                }
            }
        }

        LogosText {
            objectName: "descriptionText"
            visible: root.description !== ""
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.spacing.medium
            text: root.description
            textFormat: Text.PlainText
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
            maximumLineCount: 5
            elide: Text.ElideRight
        }

        DetailRow {
            Layout.fillWidth: true
            //: Whether the conversation is a group or a one-to-one
            key: qsTr("Type")
            value: root.isGroup ? qsTr("Group") : qsTr("Direct")
        }

        DetailRow {
            Layout.fillWidth: true
            visible: root.isGroup
            key: qsTr("Members")
            value: root.memberSummary
        }

        DetailRow {
            objectName: "peerAddressRow"
            Layout.fillWidth: true
            visible: !root.isGroup && root.peerAddress !== ""
            //: The other participant's address in a direct conversation
            key: qsTr("Address")
            value: root.peerAddress
            mono: true
            copyable: true
            onCopyRequested: value => clipboard.copy(value)
        }

        DetailRow {
            objectName: "conversationIdRow"
            Layout.fillWidth: true
            key: qsTr("Conversation")
            value: root.conversationId
            mono: true
            copyable: true
            onCopyRequested: value => clipboard.copy(value)
        }
    }
}
