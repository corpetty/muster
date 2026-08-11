import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The heading of a card in the right column: what the card holds, how many of
// them there are, and a slot for whatever acts on it. Small and lettered wide,
// so it labels the card without competing with its contents. Declare trailing
// items as children; standalone.
Item {
    id: root

    property string title
    // How many rows the card holds; negative hides the count.
    property int count: -1
    // Trailing items (a close button, an action) laid out right-aligned.
    default property alias trailing: trailingRow.data

    implicitWidth: 200
    implicitHeight: 24

    RowLayout {
        anchors.fill: parent
        spacing: Theme.spacing.small

        LogosText {
            text: root.title
            textFormat: Text.PlainText
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
            font.weight: Theme.typography.weightBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1.1
            elide: Text.ElideRight
            Layout.alignment: Qt.AlignVCenter
        }

        Rectangle {
            objectName: "panelCount"
            visible: root.count >= 0
            implicitWidth: Math.max(20, countLabel.implicitWidth + 2 * Theme.spacing.small)
            implicitHeight: 18
            radius: height / 2
            color: Theme.palette.backgroundMuted
            border.width: 1
            border.color: Theme.palette.borderSubtle
            Layout.alignment: Qt.AlignVCenter

            LogosText {
                id: countLabel
                anchors.centerIn: parent
                text: root.count
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
            }
        }

        Item {
            Layout.fillWidth: true
        }

        RowLayout {
            id: trailingRow
            spacing: Theme.spacing.tiny
            Layout.alignment: Qt.AlignVCenter
        }
    }
}
