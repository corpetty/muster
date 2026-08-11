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

            LogosText {
                objectName: "threadTitle"
                text: root.title
                textFormat: Text.PlainText
                color: Theme.palette.text
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                elide: Text.ElideRight
                Layout.fillWidth: true
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

        Facepile {
            visible: root.isGroup && root.memberCount > 0
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
