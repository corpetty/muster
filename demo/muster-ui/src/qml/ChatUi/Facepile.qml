pragma ComponentBehavior: Bound

import QtQuick

import Logos.Theme
import Logos.Controls

// Who is in a conversation, at a glance: the first few members' avatars
// overlapped, with a count for the rest. Give it a member model and the colour
// of the surface it sits on, which the tiles are ringed in so they read as
// separate. Standalone.
Row {
    id: root

    // The MemberListModel (roles: avatarInitials, avatarRamp, isSelf).
    required property var memberModel
    // The roster's size. Taken as a property because the model reaches the view
    // as a replica, whose row count a non-view caller cannot read.
    required property int memberCount
    // How many tiles to draw before the rest become a count.
    property int maxVisible: 3
    // The surface behind the pile, which rings each tile.
    property color ringColor: Theme.palette.background
    property int avatarSize: 24

    readonly property int overflow: Math.max(0, root.memberCount - root.maxVisible)

    spacing: -Theme.spacing.tiny

    Repeater {
        model: root.memberModel

        // The ring is the surface inflated behind the tile, so an overlapped
        // neighbour never crops the initials underneath.
        Rectangle {
            id: ringed
            required property int index
            required property string avatarInitials
            required property int avatarRamp
            required property bool isSelf

            visible: ringed.index < root.maxVisible
            width: root.avatarSize + 4
            height: width
            radius: width / 2
            color: root.ringColor

            Avatar {
                anchors.centerIn: parent
                size: root.avatarSize
                initials: ringed.avatarInitials
                ramp: ringed.avatarRamp
                isSelf: ringed.isSelf
            }
        }
    }

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.overflow > 0
        width: overflowLabel.implicitWidth + 2 * Theme.spacing.small
        height: root.avatarSize
        radius: height / 2
        color: Theme.palette.backgroundMuted
        border.width: 1
        border.color: Theme.palette.borderSubtle

        LogosText {
            id: overflowLabel
            anchors.centerIn: parent
            //: Count of the group members a facepile had no room for
            text: qsTr("+%1").arg(root.overflow)
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
            font.weight: Theme.typography.weightMedium
        }
    }
}
