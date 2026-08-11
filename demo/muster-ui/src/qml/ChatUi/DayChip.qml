import QtQuick

import Logos.Theme
import Logos.Controls

// The date a run of messages belongs to, on a chip that floats over the thread
// rather than a rule that cuts it in two. Set `text`; standalone.
Rectangle {
    id: root

    property string text: ""

    implicitWidth: label.implicitWidth + 2 * Theme.spacing.medium
    implicitHeight: label.implicitHeight + 2 * Theme.spacing.tiny
    radius: height / 2
    color: Theme.palette.backgroundSecondary
    border.width: 1
    border.color: Theme.palette.borderSubtle

    LogosText {
        id: label
        anchors.centerIn: parent
        text: root.text
        textFormat: Text.PlainText
        color: Theme.palette.textTertiary
        font.pixelSize: Theme.typography.secondaryText
        font.weight: Theme.typography.weightMedium
    }
}
