import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls

// A page's title (exo-720.11): what this page is, in a word, and in a line what it is for.
// Anything put inside sits at the right (the page's one Primary action). Every page —
// Needs you, Wallet, Contacts, Learn, Settings, Start something — opens the same way.
RowLayout {
    id: header
    property string title: ""
    property string subtitle: ""
    default property alias trailing: slot.data

    Layout.fillWidth: true
    spacing: Theme.spacing.medium

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        LogosText {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: header.title
            color: Theme.palette.text
            font.pixelSize: MusterStyle.title
            font.weight: Theme.typography.weightBold
        }
        LogosText {
            textFormat: Text.PlainText
            visible: header.subtitle.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: header.subtitle
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.body
        }
    }
    Row { id: slot; Layout.alignment: Qt.AlignTop; spacing: Theme.spacing.small }
}
