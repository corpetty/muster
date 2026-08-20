import QtQuick
import QtQuick.Layouts

// A clickable list entry (prototype `.row`): heading + optional subtitle +
// trailing tag, with a `live` accent (prototype `.row.live`). Named ListRow to
// avoid clashing with QtQuick's Row positioner. Presentational only — emits
// `activated()`; it holds no state and makes no claims.
Rectangle {
    id: row
    property string heading: ""
    property string subtitle: ""
    property string trailing: ""
    property bool live: false
    signal activated()

    implicitHeight: body.implicitHeight + Theme.spacing.medium * 2
    color: Theme.palette.surface
    border.color: row.live ? Theme.palette.text : Theme.palette.border
    border.width: row.live ? 2 : 1
    radius: Theme.radius.medium

    Rectangle {                 // live left accent (prototype .row.live)
        visible: row.live
        width: 4
        radius: 2
        color: Theme.palette.accent
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 3 }
    }

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: row.live ? Theme.spacing.large : Theme.spacing.medium
        anchors.rightMargin: Theme.spacing.medium
        spacing: Theme.spacing.tiny

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            Text {
                Layout.fillWidth: true
                text: row.heading
                font.family: Theme.typography.sans
                font.pixelSize: Theme.typography.rowTitleSize
                font.weight: Theme.typography.weightSemiBold
                color: Theme.palette.text
                elide: Text.ElideRight
            }
            Text {
                visible: row.trailing !== ""
                text: row.trailing
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.labelSize
                color: Theme.palette.textMuted
            }
        }
        Text {
            visible: row.subtitle !== ""
            Layout.fillWidth: true
            text: row.subtitle
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.labelSize
            color: Theme.palette.textMuted
            elide: Text.ElideRight
        }
    }

    MouseArea { anchors.fill: parent; onClicked: row.activated() }
}
