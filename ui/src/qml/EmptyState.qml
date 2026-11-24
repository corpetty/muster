import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls

// Nothing here yet, and what to do about it (exo-720.5): "Nothing waits on you. Start
// something with someone." An action, if any, goes inside.
Rectangle {
    id: empty

    property string text: ""
    default property alias actions: slot.data

    implicitHeight: col.implicitHeight + 2 * Theme.spacing.xlarge
    radius: Theme.spacing.radiusLarge
    color: "transparent"
    border.width: 1
    border.color: Theme.palette.border

    ColumnLayout {
        id: col
        anchors.centerIn: parent
        width: parent.width - 2 * Theme.spacing.xlarge
        spacing: Theme.spacing.medium
        LogosText {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: empty.text
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.body
        }
        Row { id: slot; Layout.alignment: Qt.AlignHCenter; spacing: Theme.spacing.small }
    }
}
