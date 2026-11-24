import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls

// One row of the sidebar (exo-720.6): a destination or a room. An icon (or, for a room, an
// avatar), a label, an optional line under it, and at the right a count or a "needs you"
// dot. In the rail it is the icon alone, with the label as its tooltip (icons draw only
// under GL, and the rail must still say where each row goes).
Rectangle {
    id: row

    property string label: ""
    property string detail: ""            // a second line: what waits on you, the last message
    property bool detailHot: false        // the second line waits on you
    property url icon: ""
    property string avatarId: ""          // set for a room: its avatar instead of an icon
    property string avatarName: ""
    property bool avatarIsRoom: true      // a room's rounded square; false for a person's circle
    property int count: 0
    property bool needs: false            // the "waits on you" dot
    property bool unread: false           // active since you last looked (exo-773): bold, a quiet dot
    property bool current: false
    property bool rail: false
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: detail.length > 0 && !rail ? 46 : 36
    radius: Theme.spacing.radiusMedium
    color: current ? Theme.palette.surface : hover.hovered ? Theme.palette.backgroundSecondary : "transparent"
    border.width: activeFocus ? 2 : 0
    border.color: Theme.palette.focus
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: label + (count > 0 ? ", " + count : "") + (needs ? ", waits on you" : "")
    Accessible.onPressAction: row.clicked()
    Keys.onReturnPressed: row.clicked()
    Keys.onSpacePressed: row.clicked()

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: row.rail ? 0 : Theme.spacing.small + 2
        anchors.rightMargin: row.rail ? 0 : Theme.spacing.small
        spacing: Theme.spacing.small + 2

        Item {
            Layout.preferredWidth: row.avatarId.length > 0 ? 28 : 20
            Layout.preferredHeight: Layout.preferredWidth
            Layout.alignment: row.rail ? Qt.AlignHCenter : Qt.AlignVCenter
            Layout.fillWidth: row.rail
            Avatar {
                visible: row.avatarId.length > 0
                anchors.centerIn: parent
                identity: row.avatarId
                name: row.avatarName.length > 0 ? row.avatarName : row.label
                room: row.avatarIsRoom
                size: 28
            }
            LogosIcon {
                visible: row.avatarId.length === 0
                anchors.centerIn: parent
                width: 18; height: 18
                source: row.icon
                color: row.current ? Theme.palette.text : Theme.palette.textSecondary
            }
            // in the rail, the count and the dot ride on the icon's corner
            Rectangle {
                visible: row.rail && (row.needs || row.unread || row.count > 0)
                x: parent.width - width / 2 - 2; y: -3
                width: row.count > 0 ? Math.max(16, railCount.implicitWidth + 8) : 9
                height: row.count > 0 ? 16 : 9
                radius: height / 2
                color: row.needs || row.count > 0 ? MusterStyle.needs : Theme.palette.textSecondary
                border.width: 2
                border.color: Theme.palette.backgroundTertiary
                LogosText {
                    textFormat: Text.PlainText
                    id: railCount
                    visible: row.count > 0
                    anchors.centerIn: parent
                    text: String(row.count)
                    color: Theme.palette.background
                    font.pixelSize: 10
                    font.weight: Theme.typography.weightBold
                }
            }
        }
        ColumnLayout {
            visible: !row.rail
            Layout.fillWidth: true
            spacing: 0
            LogosText {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: row.label
                elide: Text.ElideRight
                color: row.current || row.needs || row.unread ? Theme.palette.text : Theme.palette.textSecondary
                font.pixelSize: MusterStyle.body
                font.weight: row.needs || row.unread ? Theme.typography.weightBold : Theme.typography.weightMedium
            }
            LogosText {
                textFormat: Text.PlainText
                visible: row.detail.length > 0
                Layout.fillWidth: true
                text: row.detail
                elide: Text.ElideRight
                color: row.detailHot ? MusterStyle.needs : Theme.palette.textTertiary
                font.pixelSize: MusterStyle.caption
            }
        }
        Rectangle {
            visible: !row.rail && row.count > 0
            implicitWidth: Math.max(20, countLabel.implicitWidth + 12)
            implicitHeight: 20
            radius: 10
            color: MusterStyle.needs
            LogosText {
                textFormat: Text.PlainText
                id: countLabel
                anchors.centerIn: parent
                text: String(row.count)
                color: Theme.palette.background
                font.pixelSize: MusterStyle.badge
                font.weight: Theme.typography.weightBold
            }
        }
        Rectangle {
            objectName: row.unread && !row.needs ? "unreadDot" : ""
            visible: !row.rail && (row.needs || row.unread) && row.count === 0
            implicitWidth: 8; implicitHeight: 8; radius: 4
            color: row.needs ? MusterStyle.needs : Theme.palette.textSecondary
        }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: row.clicked() }
    LogosToolTip { visible: row.rail && hover.hovered; text: row.detail.length > 0 ? row.label + " — " + row.detail : row.label }
}
