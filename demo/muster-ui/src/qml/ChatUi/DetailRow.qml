import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// One fact about a conversation: its name on the left, its value on the right,
// and a copy beside the value when the value is something to take rather than
// only to read. Set `mono` for a value made of hex. Standalone.
Rectangle {
    id: root

    required property string key
    required property string value
    // Whether the value is a hex identifier, which reads and copies better in
    // fixed-width glyphs.
    property bool mono: false
    // Whether to offer a copy of the value.
    property bool copyable: false

    signal copyRequested(string value)

    implicitWidth: 200
    implicitHeight: 32
    color: "transparent"

    // A hairline above rather than a box around, so a run of rows reads as one
    // table.
    Rectangle {
        anchors.top: parent.top
        width: parent.width
        height: 1
        color: Theme.palette.borderSubtle
    }

    RowLayout {
        anchors.fill: parent
        spacing: Theme.spacing.small

        LogosText {
            text: root.key
            textFormat: Text.PlainText
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
            Layout.alignment: Qt.AlignVCenter
        }

        LogosText {
            objectName: "detailValue"
            text: root.value
            textFormat: Text.PlainText
            color: Theme.palette.textSecondary
            font.family: root.mono ? Theme.typography.mono : Theme.typography.publicSans
            font.pixelSize: Theme.typography.secondaryText
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
        }

        ChatIconButton {
            id: copyButton
            objectName: "copyDetailButton"
            visible: root.copyable
            size: 24
            iconSize: 12
            iconSource: Qt.resolvedUrl("icons/copy.png")
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Copy %1").arg(root.key)
            onClicked: root.copyRequested(root.value)
            Layout.alignment: Qt.AlignVCenter

            LogosToolTip {
                text: qsTr("Copy %1").arg(root.key)
                placement: LogosToolTip.Left
                visible: copyButton.hovered
            }
        }
    }
}
