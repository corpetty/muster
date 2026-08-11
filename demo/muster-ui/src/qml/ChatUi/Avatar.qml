import QtQuick

import Logos.Theme
import Logos.Controls

// An identity's avatar: a gradient tile carrying its initials, or a group's
// glyph. A group is squared off so it reads apart from a person at a glance,
// and this account's own entries take the brand ramp. Set the model's
// avatarInitials and avatarRamp roles; standalone.
Rectangle {
    id: root

    // Colour ramp index, from a model's avatarRamp role.
    required property int ramp
    // Two-letter identity label, from a model's avatarInitials role. Not drawn
    // for a group, which carries a glyph instead.
    property string initials: ""
    property bool isGroup: false
    // This account's own entry, which takes the brand ramp whatever its index.
    property bool isSelf: false
    // Whether to mark connectivity on the tile's edge; only this account has a
    // connection to report.
    property bool showPresence: false
    property bool online: false
    property int size: 40

    implicitWidth: root.size
    implicitHeight: root.size
    radius: root.isGroup ? Math.round(root.size * 0.34) : root.size / 2
    // Stands in when a ramp index is out of range, so a tile is never invisible.
    color: Theme.palette.surfaceContrast
    gradient: root.isSelf ? ChatTheme.selfAvatarRamp : ChatTheme.avatarRamps[root.ramp]

    LogosText {
        anchors.centerIn: parent
        visible: !root.isGroup
        text: root.initials
        textFormat: Text.PlainText
        color: ChatTheme.avatarInk
        font.family: Theme.typography.mono
        // The label scales with the tile: the design's 40px avatar carries the
        // body step and the smaller ones step down with it.
        font.pixelSize: Math.max(9, Math.round(root.size * 0.36))
        font.weight: Theme.typography.weightBold
    }

    // Drawn straight rather than tinted: its colour never changes, and the
    // design system's tinting path needs a shader the hosts may not have.
    Image {
        anchors.centerIn: parent
        visible: root.isGroup
        source: Qt.resolvedUrl("icons/group.png")
        width: Math.round(root.size * 0.55)
        height: width
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectFit
        opacity: 0.74
    }

    // On the tile's edge rather than at the corner of its bounding box, where a
    // circular avatar would leave it floating.
    Rectangle {
        visible: root.showPresence
        x: root.width - width - 1
        y: root.height - height - 1
        implicitWidth: Math.max(8, Math.round(root.size * 0.3))
        implicitHeight: width
        radius: width / 2
        color: root.online ? ChatTheme.settled : Theme.palette.textTertiary
        border.width: 2
        border.color: Theme.palette.backgroundTertiary
    }
}
