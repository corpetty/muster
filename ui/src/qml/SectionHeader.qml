import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls

// A section's label (exo-720.5): "In the room · 3", "Disclosed into this room". Sections
// are told apart by their headers and the surfaces under them, never by hairlines alone.
// `hot` marks a section that waits on you. Anything put inside sits at the right
// (a count, an "Invite" link).
RowLayout {
    id: header

    property string text: ""
    property string count: ""
    property bool hot: false
    default property alias trailing: slot.data

    spacing: Theme.spacing.small
    Layout.fillWidth: true

    LogosText {
        textFormat: Text.PlainText
        text: header.count.length > 0 ? header.text + " · " + header.count : header.text
        color: header.hot ? MusterStyle.needs : Theme.palette.textTertiary
        font.pixelSize: MusterStyle.caption
        font.weight: Theme.typography.weightBold
        Layout.fillWidth: true
        elide: Text.ElideRight
    }
    Row { id: slot; spacing: Theme.spacing.small }
}
