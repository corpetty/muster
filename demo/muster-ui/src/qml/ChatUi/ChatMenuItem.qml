import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A menu entry that names an action and says what it does: a glyph, the entry's
// text, and a line of explanation under it. For a menu offering choices a first
// user cannot tell apart from their names alone. Standalone.
LogosMenuItem {
    id: root

    property url iconSource: ""
    // What the entry does, in a few words under its name.
    property string description: ""

    implicitHeight: 44

    contentItem: RowLayout {
        spacing: Theme.spacing.small

        LogosIcon {
            source: root.iconSource
            color: root.highlighted ? Theme.palette.text : Theme.palette.textSecondary
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18
            Layout.leftMargin: Theme.spacing.small
            Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.rightMargin: Theme.spacing.medium
            spacing: 0

            LogosText {
                text: root.text
                textFormat: Text.PlainText
                color: root.enabled ? Theme.palette.text : Theme.palette.textMuted
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightMedium
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            LogosText {
                visible: root.description !== ""
                text: root.description
                textFormat: Text.PlainText
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }
}
