import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The open conversation's identity above its thread: its avatar, its name, one
// line of description, who is in it, and the toggle for the rest of its facts.
// Data in via properties, intent out via detailsToggled. Standalone.
Rectangle {
    id: root

    required property string title
    // One line under the title; empty for a conversation without one.
    property string description: ""
    required property bool isGroup
    required property string avatarInitials
    required property int avatarRamp
    // The roster behind the facepile; omitted for a conversation with no group.
    property var memberModel: null
    property int memberCount: 0
    // Invited but not yet committed; they cannot read anything yet.
    property int pendingMemberCount: 0
    // Whether delivery is up, so the scope line does not claim a live boundary
    // when nothing is being delivered.
    property bool online: false
    // What is in flight here, as a headline — "Paying 100 LEZ", "They need an
    // address". Empty when nothing is, and the conversation's name leads again.
    property string action: ""
    // Whether the details panel this toggle opens is showing.
    property bool detailsShown: false

    signal detailsToggled

    implicitWidth: 400
    implicitHeight: 76
    color: "transparent"
    clip: true

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacing.xlarge
        anchors.rightMargin: Theme.spacing.xlarge
        spacing: Theme.spacing.medium

        Avatar {
            initials: root.avatarInitials
            ramp: root.avatarRamp
            isGroup: root.isGroup
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            // What is happening leads; who it is with follows. People come back
            // to this app to do something, not to chat — so the headline is the
            // action in flight, and the name of the person it is with is the
            // context for it rather than the other way round.
            //
            // Falls back to the name when there is nothing in flight, because a
            // conversation with no action is still a conversation.
            LogosText {
                objectName: "threadTitle"
                text: root.action !== "" ? root.action : root.title
                textFormat: Text.PlainText
                color: Theme.palette.text
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // The counterparty, demoted to the subtitle when something is
            // happening. "with Bob" reads as the answer to a question the
            // headline just raised.
            LogosText {
                objectName: "threadWith"
                visible: root.action !== "" && root.title !== ""
                text: qsTr("with %1").arg(root.title)
                textFormat: Text.PlainText
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // The boundary, at the top where the conversation is named rather
            // than down by the composer: it qualifies everything below it.
            ScopeLine {
                objectName: "scopeLine"
                Layout.fillWidth: true
                Layout.topMargin: 1
                memberCount: root.memberCount
                pendingCount: root.pendingMemberCount
                online: root.online
            }

            LogosText {
                id: descriptionText
                objectName: "threadDescription"
                visible: root.description !== ""
                // One line, whatever its length: the thread below is what the
                // window is for.
                text: root.description
                textFormat: Text.PlainText
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                elide: Text.ElideRight
                Layout.fillWidth: true

                HoverHandler {
                    id: descriptionHover
                }
                // Only worth a tooltip when there is more of it to show.
                LogosToolTip {
                    text: root.description
                    placement: LogosToolTip.Bottom
                    visible: descriptionHover.hovered && descriptionText.truncated
                }
            }
        }

        // The nameplate: who is actually in the room, beside the line claiming
        // how many can read it. Shown for a direct conversation too — two faces
        // next to "2 can read" is what makes that number checkable instead of
        // asserted, which is the whole difference between drawing a boundary
        // and describing one.
        Facepile {
            visible: root.memberCount > 0
            memberModel: root.memberModel
            memberCount: root.memberCount
            ringColor: Theme.palette.background
            Layout.alignment: Qt.AlignVCenter
        }

        ChatIconButton {
            id: detailsButton
            objectName: "detailsButton"
            lit: root.detailsShown
            iconSource: Qt.resolvedUrl("icons/info.png")
            Accessible.role: Accessible.Button
            //: Button that shows the conversation's details
            Accessible.name: qsTr("Details")
            onClicked: root.detailsToggled()
            Layout.alignment: Qt.AlignVCenter

            LogosToolTip {
                text: qsTr("Details")
                placement: LogosToolTip.Bottom
                visible: detailsButton.hovered
            }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.palette.borderSubtle
    }
}
